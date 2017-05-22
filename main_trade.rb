require 'ruby_coincheck_client'
require 'bigdecimal'
require "thor"
require "pry"
require 'chronic'
require './technical_analysis_services/bollinger_band_service'
require './util/http_module'
include HttpModule
require './util/chatwork_service'

running_back_test = false
ARGV.each do |argv|
  # コマンド引数に"test"とあったらバックテスト運用
  running_back_test = true if argv == "test"
end

CHATWORK_API_ID = ENV["CHATWORK_API_ID"]
CHATWORK_ROOM_ID = ENV["CHATWORK_ROOM_ID"]

ACCESS_FAIL_INTERVAL_TIME = 3

if running_back_test
  # BASE_URL = "http://localhost:3000/"
  BASE_URL = "http://192.168.11.6:3000/"
  SSL = false
  HEADER = {
      "Content-Type" => "application/json",
      "ACCESS-KEY" => USER_KEY
  }

  USER_KEY = "aaaaa"
  USER_SECRET_KEY = "vvvvvv"
  INTERVAL_TIME = 0
else
  BASE_URL = "https://coincheck.jp/"
  SSL = true

  USER_KEY = ENV["COIN_CHECK_ACCESS_KEY"]
  USER_SECRET_KEY = ENV["COIN_CHECK_SECRET_KEY"]
  INTERVAL_TIME = 10
end

if running_back_test
  # 登録済みヒストリカルデータより開始時間を設定
  uri = URI.parse(BASE_URL + "api/set_test_trade_time")
  request_for_put(uri, HEADER)

  # 検証用の証拠金を設定
  test_margin = 200_000
  uri = URI.parse(BASE_URL + "api/set_user_leverage_balance?margin=#{test_margin}")
  request_for_put(uri, HEADER)
  puts "テスト証拠金：#{test_margin}円セット"

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

loop do
  # 強制終了の確認
  begin
    messages = chat.get_message
    if messages.find { |msg| msg == "強制終了" }
      chat.send_message(message: "強制終了します")
      break
    elsif messages.find { |msg| msg == "動作確認" }
      chat.send_message(message: "処理実行しています")
    end

    # 現在のレート確認
    rate_res = cc.read_ticker
    btc_jpy_bid_rate =  BigDecimal(JSON.parse(rate_res.body)['bid']) # 現在の買い注文の最高価格
    btc_jpy_ask_rate =  BigDecimal(JSON.parse(rate_res.body)['ask']) # 現在の売り注文の最安価格
    timestamp =  JSON.parse(rate_res.body)['timestamp'].to_i
    btc_jpy_rate = (btc_jpy_bid_rate + btc_jpy_ask_rate)/2
    bollinger_band_service.set_rate(rate: btc_jpy_rate,
                                    timestamp: timestamp)

    result = bollinger_band_service.check_signal_exec(rate: btc_jpy_rate,
                                                      timestamp: timestamp) # 試験的に
    # if result != BollingerBandService::LACK_DATA
    #   puts result
    # end


    # ポジションの確認
    sleep 1
    response = cc.read_positions(status: "open")
    positions = JSON.parse(response.body)["data"]


    # 証拠金の確認
    sleep 1
    response = cc.read_leverage_balance
    margin_available = JSON.parse(response.body)['margin_available']['jpy']

    if positions.empty?
      # ポジション無し
      if result == BollingerBandService::SHORT
        sleep 1
        # ショートポジション
        order_amount = (margin_available / btc_jpy_bid_rate * 5).to_f.round(2)
        response = cc.create_orders(order_type: "leverage_sell",
                                    rate: btc_jpy_bid_rate.to_i,
                                    amount: order_amount,
                                    market_buy_amount: nil,
                                    position_id: nil,
                                    pair: "btc_jpy")

        message = "#{Time.at(timestamp)}に#{btc_jpy_bid_rate.to_i}円でショート"
        puts message
        chat.send_message(message: message)

      elsif result == BollingerBandService::LONG
        sleep 1
        # ロングポジション
        order_amount = (margin_available / btc_jpy_bid_rate * 5).to_f.round(2)
        response = cc.create_orders(order_type: "leverage_buy",
                                    rate: btc_jpy_ask_rate.to_i,
                                    amount: order_amount,
                                    market_buy_amount: nil,
                                    position_id: nil,
                                    pair: "btc_jpy")

        message = "#{Time.at(timestamp)}に#{btc_jpy_ask_rate.to_i}円でロング"
        puts message
        chat.send_message(message: message)
      end

    else
      open_rate = positions[0]["open_rate"]
      # 1.5%以上の利益で利確
      # -2.0%以下のロス発生で損切り
      if positions[0]["side"] == "buy"
        sleep 1
        gain_rate = (open_rate * 1.015).to_i
        loss_cut_rate = (open_rate * 0.98).to_i
        if gain_rate <= btc_jpy_ask_rate || loss_cut_rate >= btc_jpy_ask_rate
          # 現在の売り注文が利確金額以上なら利確
          # 現在の売り注文が損切り金額以下なら損切り
          response = cc.create_orders(order_type: "close_long",
                                      rate: btc_jpy_ask_rate.to_i,
                                      amount: positions.first["amount"],
                                      market_buy_amount: nil,
                                      position_id: positions.first["id"],
                                      pair: "btc_jpy")

          trade_type = if gain_rate <= btc_jpy_ask_rate
                         "利確"
                       else
                         "損切"
                       end
          message = "#{Time.at(timestamp)}に#{positions[0]['open_rate']}円のロングポジションを#{btc_jpy_ask_rate.to_i}で#{trade_type}"
          puts message
          chat.send_message(message: message)
        end

      elsif positions[0]["side"] == "sell"
        sleep 1
        gain_rate = (open_rate * 0.985).to_i
        loss_cut_rate = (open_rate * 1.02).to_i
        if gain_rate >= btc_jpy_bid_rate || loss_cut_rate <= btc_jpy_bid_rate
          # 現在の買い注文が利確金額以下なら利確
          # 現在の買い注文が損切り金額以上なら損切り
          response = cc.create_orders(order_type: "close_short",
                                      rate: btc_jpy_bid_rate.to_i,
                                      amount: positions.first["amount"],
                                      market_buy_amount: nil,
                                      position_id: positions.first["id"],
                                      pair: "btc_jpy")

          trade_type = if gain_rate >= btc_jpy_bid_rate
                         "利確"
                       else
                         "損切"
                       end
          message = "#{Time.at(timestamp)}に#{positions[0]['open_rate']}円のショートポジションを#{btc_jpy_ask_rate.to_i}で#{trade_type}"
          puts message
          chat.send_message(message: message)
        end
      end
    end

    # INTERVAL_TIME秒待機
    sleep INTERVAL_TIME

    if running_back_test
      # 待機時間分、User.start_trade_timeを加算する
      uri = URI.parse(BASE_URL + "api/update_start_trade_time?interval_time=#{INTERVAL_TIME}")
      request_for_put(uri, HEADER)

      # 登録済みテストデータ分の処理を実行したかを確認
      uri = URI.parse(BASE_URL + "api/check_test_trade_is_over")
      response = request_for_get(uri, HEADER)

      if JSON.parse(response.body)["test_trade_is_over?"]

        # ポジションの強制決済
        sleep 1
        res = cc.read_positions(status: "open")
        positions = JSON.parse(res.body)["data"]
        unless positions.empty?
          if positions[0]["side"] == "buy"
            cc.create_orders(order_type: "close_long",
                             rate: btc_jpy_ask_rate.to_i,
                             amount: positions.first["amount"],
                             market_buy_amount: nil,
                             position_id: positions.first["id"],
                             pair: "btc_jpy")
          else
            cc.create_orders(order_type: "close_short",
                             rate: btc_jpy_bid_rate.to_i,
                             amount: positions.first["amount"],
                             market_buy_amount: nil,
                             position_id: positions.first["id"],
                             pair: "btc_jpy")
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
    sleep ACCESS_FAIL_INTERVAL_TIME
    next
  end
end
