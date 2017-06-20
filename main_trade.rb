require 'ruby_coincheck_client'
require 'bigdecimal'
require "thor"
require "pry"
require 'chronic'
require './technical_analysis_services/bollinger_band_service'
Dir["./util/*.rb"].each do |file|
  require file
end
# require './util/http_module'

Dir["./trade_style/*.rb"].each do |file|
  require file
end

include HttpModule
include SeedSaveModule
require "google_drive"
require 'logger'

running_back_test = false
save_seed = false
init_gene_code = nil
order_executable = true

if defined?(PryByebug)
  Pry.commands.alias_command 'c', 'continue'
  Pry.commands.alias_command 's', 'step'
  Pry.commands.alias_command 'n', 'next'
  Pry.commands.alias_command 'f', 'finish'
end

ARGV.each do |argv|
  # コマンド引数に"test"とあったらバックテスト運用
  running_back_test = true if argv == "test"
  # コマンド引数に"seed"とあったらseed用データ保存
  save_seed = true if argv == "seed"

  # コマンド引数に"0"と"1"で構成されている文字列(遺伝子コード)があったらその設定をインジケーターに反映させる
  if argv.match(/^[01]{0,50}$/)
    init_gene_code = argv
  end

  match_date = argv.match(/^double_position(?<gene_code>\d{8,10})$/)
  if match_date
    seed_dir_name = match_date[:gene_code]
    next
  end

  # コマンド引数に"non_order"とあったら発注処理は実施しない
  order_executable = true if argv == "non_order"
end

logger = Logger.new("trade.log", "weekly")

CHATWORK_API_ID = ENV["CHATWORK_API_ID"]
CHATWORK_ROOM_ID = ENV["CHATWORK_ROOM_ID"]

ACCESS_FAIL_INTERVAL_TIME = 3
INTERVAL_TIME = 10

GOOGLE_CLIENT_ID = ENV["GOOGLE_CLIENT_ID"]
GOOGLE_SERCRET_KEY = ENV["GOOGLE_SERCRET_KEY"]
OAUTH_CODE = ENV["OAUTH_CODE"]
REFRESH_TOKEN = ENV["REFRESH_TOKEN"]
SPREAD_SHEET_KEY = ENV["SPREAD_SHEET_KEY"]

if running_back_test
  COIN_CHECK_BASE_URL = "http://localhost:3000/"
  # BASE_URL = "http://192.168.11.6:3000/"
  USER_KEY = "ayddsdddt"
  USER_SECRET_KEY = "vvvvvv"
  SSL = false
  HEADER = {
      "Content-Type" => "application/json",
      "ACCESS-KEY" => USER_KEY
  }
else
  COIN_CHECK_BASE_URL = "https://coincheck.jp/"
  USER_KEY = ENV["COIN_CHECK_ACCESS_KEY"]
  USER_SECRET_KEY = ENV["COIN_CHECK_SECRET_KEY"]
  SSL = true
end

if running_back_test
  # 登録済みヒストリカルデータより開始時間を設定
  uri = URI.parse(COIN_CHECK_BASE_URL + "api/set_test_trade_time")
  request_for_put(uri, HEADER)

  # 検証用の証拠金を設定
  test_margin = 200_000
  uri = URI.parse(COIN_CHECK_BASE_URL + "api/set_user_leverage_balance?margin=#{test_margin}")
  request_for_put(uri, HEADER)
  msg = "テスト証拠金：#{test_margin}円セット"
  puts msg
  logger.info(msg)

  # ポジションの初期化
  uri = URI.parse(COIN_CHECK_BASE_URL + "api/delete_all_positions")
  request_for_delete(uri, HEADER)

  # public APIに相当するgemのメソッドはパラメータを渡せないから過去データ検証ができない。
  # 代替案ができるまでAPIを直接呼ぶようにします。
  # 過去データの検証のためには引数を渡すか、呼び出された先でuserの判別ができれば良いが、
  # 前者は引数を渡す、ということでgemのメソッドの形を変えてしまうので、今回は後者で対応
  # gemのメソッドをオーバーライドします
  class CoincheckClient
    def read_ticker
      uri = URI.parse(COIN_CHECK_BASE_URL + "api/ticker")
      request_for_get(uri, HEADER)
    end

    def read_trades
      uri = URI.parse(COIN_CHECK_BASE_URL + "api/trades")
      request_for_get(uri, HEADER)
    end

    def read_order_books
      uri = URI.parse(COIN_CHECK_BASE_URL + "api/order_books")
      request_for_get(uri, HEADER)
    end
  end
end

class CoincheckClient
  # レート取得するメソッドがない。オーバーライドで作る
  # tickerの中間値はどうも信用できないので独自にAPIを叩きに行くようするようにする
  # TODO こっちはAPIの方が使えない
  # def original_read_exchange_order_rate(order_type:, pair: "btc_jpy")
  #   uri = URI.parse(COIN_CHECK_BASE_URL + "/api/exchange/orders/rate")
  #   body = {
  #       order_type: order_type,
  #       pair: pair
  #   }
  #   request_for_get(uri, HEADER, body)
  # end

  def original_read_rate(pair: "btc_jpy")
    uri = URI.parse(COIN_CHECK_BASE_URL + "api/rate/#{pair}")
    request_for_get(uri, HEADER)
  end
end

cc = CoincheckClient.new(USER_KEY,
                         USER_SECRET_KEY,
                         {base_url: COIN_CHECK_BASE_URL,
                          ssl: SSL})

go_spreadsheet_service = GoSpreadSheetService.new(GOOGLE_CLIENT_ID,
                                                  GOOGLE_SERCRET_KEY,
                                                  REFRESH_TOKEN,
                                                  SPREAD_SHEET_KEY)

chat = ChatworkService.new(CHATWORK_API_ID, CHATWORK_ROOM_ID, true)

bollinger_band_service_params = {}
if init_gene_code
  bollinger_band_service_params = {
      range_sec: init_gene_code[0..8].to_i(2), # 足の単位時間
      significant_point: init_gene_code[9..11].to_i(2), # 外れ値判定の有意点
      expansion_check_range: init_gene_code[12..15].to_i(2), # エクスパンション判定の標本数
      constrict_values_box_max_size: init_gene_code[16..20].to_i(2), # くびれチェック
      balance_rate: init_gene_code[21..30].to_i(2),
      short_range_start: init_gene_code[31..34].to_i(2),
      short_range_end: init_gene_code[35..38].to_i(2),
      long_range_start: init_gene_code[39..44].to_i(2),
      long_range_end: init_gene_code[45..50].to_i(2)
  }
end
bollinger_band_service = BollingerBandService.new(chat, bollinger_band_service_params, go_spreadsheet_service)
order_service = OrderService.new(cc, logger, chat, order_executable, running_back_test)

id = 1

if save_seed
  # レート取得の為、httpインスタンス作成
  uri = URI.parse("https://coincheck.jp/api/rate/btc_jpy")
  btc_jpy_https = Net::HTTP.new(uri.host, uri.port)
  btc_jpy_https.use_ssl = true

  # データ格納用のディレクトリ作成
  path = "#{File.expand_path(File.dirname($0))}/seed_datas/#{Time.now.strftime("%Y%m%d")}"
  FileUtils.mkdir_p(path) unless FileTest.exist?(path)

  # ヘッダ行の作成
  save_header_csv(path)
end

count = 0
# trade_style = MaxAndSinglePositionBollinger.new(coincheck_client: cc,
#                                                 bollinger_band_service: bollinger_band_service,
#                                                 logger: logger,
#                                                 running_back_test: running_back_test,
#                                                 order_service: order_service)

trade_style = DoublePosition.new(coincheck_client: cc,
                                 logger: logger,
                                 running_back_test: running_back_test,
                                 go_spreadsheet_service: go_spreadsheet_service,
                                 order_service: order_service)

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
      save_seed_csv(cc, path, id, btc_jpy_https)
      id += 1
    end

    # トレード実施
    trade_style.execute

    # INTERVAL_TIME秒待機
    sleep INTERVAL_TIME unless running_back_test
    if (count%200).zero?
      puts "現在#{count}番目"
    end
    count += 1

    if running_back_test
      rate_res = trade_style.response_read_ticker
      btc_jpy_bid_rate =  BigDecimal(JSON.parse(rate_res.body)['bid']) # 現在の買い注文の最高価格
      btc_jpy_ask_rate =  BigDecimal(JSON.parse(rate_res.body)['ask']) # 現在の売り注文の最安価格
      timestamp =  JSON.parse(rate_res.body)['timestamp'].to_i

      # 待機時間分、User.start_trade_timeを加算する
      uri = URI.parse(COIN_CHECK_BASE_URL + "api/update_start_trade_time?interval_time=#{INTERVAL_TIME}")
      request_for_put(uri, HEADER)

      # 登録済みテストデータ分の処理を実行したかを確認
      uri = URI.parse(COIN_CHECK_BASE_URL + "api/check_test_trade_is_over")
      response = request_for_get(uri, HEADER)

      if JSON.parse(response.body)["test_trade_is_over?"]
        # ポジションの強制決済
        sleep 1 unless running_back_test
        res = cc.read_positions(status: "open")
        positions = JSON.parse(res.body)["data"]
        unless positions.empty?

          positions.each do |position|
            if position["side"] == "buy"
              message = "#{Time.at(timestamp)}に#{position['open_rate']}円のロングポジションを#{btc_jpy_ask_rate.to_i}で強制決済"

              order_service.execute(order_type: "close_long",
                                    rate: btc_jpy_ask_rate.to_i,
                                    amount: position["amount"],
                                    market_buy_amount: nil,
                                    position_id: position["id"],
                                    pair: "btc_jpy",
                                    timestamp: timestamp,
                                    message: message)
            else
              message = "#{Time.at(timestamp)}に#{position['open_rate']}円のショートポジションを#{btc_jpy_bid_rate.to_i}で強制決済"
              order_service.execute(order_type: "close_short",
                                    rate: btc_jpy_ask_rate.to_i,
                                    amount: position["amount"],
                                    market_buy_amount: nil,
                                    position_id: position["id"],
                                    pair: "btc_jpy",
                                    timestamp: timestamp,
                                    message: message)
            end
          end
        end

        # レバレッジマージン情報を取得
        uri = URI.parse(COIN_CHECK_BASE_URL + "api/check_test_trade_is_over")
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
