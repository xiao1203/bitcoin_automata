require 'ruby_coincheck_client'
require 'bigdecimal'
require "thor"
require "pry"
require 'chronic'
require './technical_analysis_services/bollinger_band_service'
require './util/http_module'
require './util/order_module'
require './util/seed_save_module'
require './util/chatwork_service'
include HttpModule
include OrderModule
include SeedSaveModule

require 'logger'

running_back_test = false
save_seed = false
ARGV.each do |argv|
  # コマンド引数に"test"とあったらバックテスト運用
  running_back_test = true if argv == "test"
  # コマンド引数に"seed"とあったらseed用データ保存
  save_seed = true if argv == "seed"
end

logger = Logger.new("trade.log", "weekly")

CHATWORK_API_ID = ENV["CHATWORK_API_ID"]
CHATWORK_ROOM_ID = ENV["CHATWORK_ROOM_ID"]

ACCESS_FAIL_INTERVAL_TIME = 3
INTERVAL_TIME = 10

if running_back_test
  # BASE_URL = "http://localhost:3000/"
  BASE_URL = "http://192.168.11.6:3000/"
  USER_KEY = "aaaaa"
  USER_SECRET_KEY = "vvvvvv"
  SSL = false
  HEADER = {
      "Content-Type" => "application/json",
      "ACCESS-KEY" => USER_KEY
  }
else
  BASE_URL = "https://coincheck.jp/"
  USER_KEY = ENV["COIN_CHECK_ACCESS_KEY"]
  USER_SECRET_KEY = ENV["COIN_CHECK_SECRET_KEY"]
  SSL = true
end

if running_back_test
  # 登録済みヒストリカルデータより開始時間を設定
  uri = URI.parse(BASE_URL + "api/set_test_trade_time")
  request_for_put(uri, HEADER)

  # 検証用の証拠金を設定
  test_margin = 200_000
  uri = URI.parse(BASE_URL + "api/set_user_leverage_balance?margin=#{test_margin}")
  request_for_put(uri, HEADER)
  msg = "テスト証拠金：#{test_margin}円セット"
  puts msg
  logger.info(msg)

  # public APIに相当するgemのメソッドはパラメータを渡せないから過去データ検証ができない。
  # 代替案ができるまでAPIを直接呼ぶようにします。
  # 過去データの検証のためには引数を渡すか、呼び出された先でuserの判別ができれば良いが、
  # 前者は引数を渡す、ということでgemのメソッドの形を変えてしまうので、今回は後者で対応
  # gemのメソッドをオーバーライドします
  class CoincheckClient
    def read_ticker
      uri = URI.parse(BASE_URL + "api/ticker")
      request_for_get(uri, HEADER)
    end

    def read_trades
      uri = URI.parse(BASE_URL + "api/trades")
      request_for_get(uri, HEADER)
    end

    def read_order_books
      uri = URI.parse(BASE_URL + "api/order_books")
      request_for_get(uri, HEADER)
    end
  end
end

cc = CoincheckClient.new(USER_KEY,
                         USER_SECRET_KEY,
                         {base_url: BASE_URL,
                          ssl: SSL})

chat = ChatworkService.new(CHATWORK_API_ID, CHATWORK_ROOM_ID, true)
bollinger_band_service = BollingerBandService.new(chat)
id = 1
btc_jpy_http = nil

if save_seed
  # レート取得の為、httpインスタンス作成
  uri = URI.parse("https://coincheck.jp/api/rate/btc_jpy")
  btc_jpy_https = Net::HTTP.new(uri.host, uri.port)
  btc_jpy_https.use_ssl = true
end


loop do
  # 強制終了の確認
  begin
    messages = chat.get_message
    if messages.find { |msg| msg == "強制終了" }
      msg = "強制終了します"
      chat.send_message(message: msg)
      logger.info(msg)
      break
    elsif messages.find { |msg| msg == "動作確認" }
      chat.send_message(message: "処理実行しています")
    end

    if save_seed
      # データ格納用のディレクトリ作成
      path = "#{File.expand_path(File.dirname($0))}/seed_datas/#{Time.now.strftime("%Y%m%d")}"
      FileUtils.mkdir_p(path) unless FileTest.exist?(path)
      save_seed_csv(cc, path, id, btc_jpy_https)
      id += 1
    end

    # 現在のレート確認
    logger.info("read_ticker")
    rate_res = cc.read_ticker
    btc_jpy_bid_rate =  BigDecimal(JSON.parse(rate_res.body)['bid']) # 現在の買い注文の最高価格
    btc_jpy_ask_rate =  BigDecimal(JSON.parse(rate_res.body)['ask']) # 現在の売り注文の最安価格
    timestamp =  JSON.parse(rate_res.body)['timestamp'].to_i
    btc_jpy_rate = (btc_jpy_bid_rate + btc_jpy_ask_rate)/2
    bollinger_band_service.set_rate(rate: btc_jpy_rate,
                                    timestamp: timestamp)
    logger.info(    "btc_jpy_bid_rate: #{btc_jpy_bid_rate.to_i}," +
                    "btc_jpy_ask_rate: #{btc_jpy_ask_rate.to_i}," +
                    "timestamp: #{Time.at(timestamp)}," +
                    "btc_jpy_rate: #{btc_jpy_rate.to_i}")

    result = bollinger_band_service.check_signal_exec(rate: btc_jpy_rate,
                                                      timestamp: timestamp) # 試験的に
    # if result != BollingerBandService::LACK_DATA
    #   puts result
    # end

    # ポジションの確認
    sleep 1 unless running_back_test
    response = cc.read_positions(status: "open")
    positions = JSON.parse(response.body)["data"]
    logger.info("positions: #{positions}")

    # 証拠金の確認
    sleep 1 unless running_back_test
    response = cc.read_leverage_balance
    margin_available = JSON.parse(response.body)['margin_available']['jpy']
    logger.info("margin_available: #{margin_available}")

    if positions.empty?
      # ポジション無し
      if result == BollingerBandService::SHORT
        sleep 1 unless running_back_test
        order_amount = (margin_available / btc_jpy_bid_rate * 5).to_f.round(2)
        message = "#{Time.at(timestamp)}に#{btc_jpy_bid_rate.to_i}円でショート"
        # ショートポジション
        create_orders(coincheck_client: cc,
                      logger: logger,
                      chat_service: chat,
                      order_type: "leverage_sell",
                      rate: btc_jpy_bid_rate.to_i,
                      amount: order_amount,
                      market_buy_amount: nil,
                      position_id: nil,
                      pair: "btc_jpy",
                      timestamp: timestamp,
                      message: message)

      elsif result == BollingerBandService::LONG
        sleep 1 unless running_back_test
        # ロングポジション
        order_amount = (margin_available / btc_jpy_bid_rate * 5).to_f.round(2)
        message = "#{Time.at(timestamp)}に#{btc_jpy_ask_rate.to_i}円でロング"
        create_orders(coincheck_client: cc,
                      logger: logger,
                      chat_service: chat,
                      order_type: "leverage_buy",
                      rate: btc_jpy_ask_rate.to_i,
                      amount: order_amount,
                      market_buy_amount: nil,
                      position_id: nil,
                      pair: "btc_jpy",
                      timestamp: timestamp,
                      message: message)
      end

    else
      open_rate = positions[0]["open_rate"]
      # 1.5%以上の利益で利確
      # -2.0%以下のロス発生で損切り
      if positions[0]["side"] == "buy"
        sleep 1 unless running_back_test
        gain_rate = (open_rate * 1.015).to_i
        loss_cut_rate = (open_rate * 0.98).to_i
        if gain_rate <= btc_jpy_ask_rate || loss_cut_rate >= btc_jpy_ask_rate
          trade_type = if gain_rate <= btc_jpy_ask_rate
                         "利確"
                       else
                         "損切"
                       end
          message = "#{Time.at(timestamp)}に#{positions[0]['open_rate']}円のロングポジションを#{btc_jpy_ask_rate.to_i}で#{trade_type}"
          # 現在の売り注文が利確金額以上なら利確
          # 現在の売り注文が損切り金額以下なら損切り
          create_orders(coincheck_client: cc,
                        logger: logger,
                        chat_service: chat,
                        order_type: "close_long",
                        rate: btc_jpy_ask_rate.to_i,
                        amount: positions.first["amount"],
                        market_buy_amount: nil,
                        position_id: positions.first["id"],
                        pair: "btc_jpy",
                        timestamp: timestamp,
                        message: message)
        end

      elsif positions[0]["side"] == "sell"
        sleep 1 unless running_back_test
        gain_rate = (open_rate * 0.985).to_i
        loss_cut_rate = (open_rate * 1.02).to_i
        if gain_rate >= btc_jpy_bid_rate || loss_cut_rate <= btc_jpy_bid_rate
          # 現在の買い注文が利確金額以下なら利確
          # 現在の買い注文が損切り金額以上なら損切り
          trade_type = if gain_rate >= btc_jpy_bid_rate
                         "利確"
                       else
                         "損切"
                       end
          message = "#{Time.at(timestamp)}に#{positions[0]['open_rate']}円のショートポジションを#{btc_jpy_ask_rate.to_i}で#{trade_type}"
          create_orders(coincheck_client: cc,
                        logger: logger,
                        chat_service: chat,
                        order_type: "close_short",
                        rate: btc_jpy_bid_rate.to_i,
                        amount: positions.first["amount"],
                        market_buy_amount: nil,
                        position_id: positions.first["id"],
                        pair: "btc_jpy",
                        timestamp: timestamp,
                        message: message)
        end
      end
    end

    # INTERVAL_TIME秒待機
    sleep INTERVAL_TIME unless running_back_test

    if running_back_test
      # 待機時間分、User.start_trade_timeを加算する
      uri = URI.parse(BASE_URL + "api/update_start_trade_time?interval_time=#{10}")
      request_for_put(uri, HEADER)

      # 登録済みテストデータ分の処理を実行したかを確認
      uri = URI.parse(BASE_URL + "api/check_test_trade_is_over")
      response = request_for_get(uri, HEADER)

      if JSON.parse(response.body)["test_trade_is_over?"]

        # ポジションの強制決済
        sleep 1 unless running_back_test
        res = cc.read_positions(status: "open")
        positions = JSON.parse(res.body)["data"]
        unless positions.empty?
          if positions[0]["side"] == "buy"
            message = "#{Time.at(timestamp)}に#{positions[0]['open_rate']}円のロングポジションを#{btc_jpy_ask_rate.to_i}で決済"
            create_orders(coincheck_client: cc,
                          logger: logger,
                          chat_service: chat,
                          order_type: "close_long",
                          rate: btc_jpy_ask_rate.to_i,
                          amount: positions.first["amount"],
                          market_buy_amount: nil,
                          position_id: positions.first["id"],
                          pair: "btc_jpy",
                          timestamp: timestamp,
                          message: message)

          else
            message = "#{Time.at(timestamp)}に#{positions[0]['open_rate']}円のショートポジションを#{btc_jpy_bid_rate.to_i}で決済"
            create_orders(coincheck_client: cc,
                          logger: logger,
                          chat_service: chat,
                          order_type: "close_short",
                          rate: btc_jpy_bid_rate.to_i,
                          amount: positions.first["amount"],
                          market_buy_amount: nil,
                          position_id: positions.first["id"],
                          pair: "btc_jpy",
                          timestamp: timestamp,
                          message: message)

          end
        end

        # レバレッジマージン情報を取得
        uri = URI.parse(BASE_URL + "api/check_test_trade_is_over")
        response = request_for_get(uri, HEADER)
        leverage_balance = JSON.parse(response.body)["leverage_balance"]
        puts "テスト証拠金：#{leverage_balance['margin']}円になりました"
        break
      end
    end
  rescue => e
    puts e.backtrace
    logger.error(e.backtrace)
    sleep ACCESS_FAIL_INTERVAL_TIME
    next
  end
end
