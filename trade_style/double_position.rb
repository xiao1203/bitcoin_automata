class DoublePosition
  attr_accessor :response_read_ticker
  attr_accessor :response_read_trades
  attr_accessor :response_read_order_books
  attr_accessor :response_original_read_rate

  def initialize(coincheck_client: nil,
                 logger: nil,
                 running_back_test: nil,
                 order_service: nil,
                 go_spreadsheet_service: nil,
                 csv_data_list: {})

    @cc = coincheck_client
    @logger = logger
    @running_back_test = running_back_test
    @go_spreadsheet_service = go_spreadsheet_service

    # ヘッダの作成
    @go_spreadsheet_service.set_line(lines: %w(時間 スプレット),
                                     x_position: 1,
                                     y_position: 1,
                                     sheet_index: 0)

    @order_service = order_service

    @response_read_ticker
    @response_read_trades
    @response_read_order_books
    @response_original_read_rate
  end

  # トレード処理
  # 時間経過でなんども実行されることを想定
  def execute
    # 現在のレート確認
    @response_read_ticker = @cc.read_ticker
    # 現在の買い注文の最高価格(つまり、こっちが売る(shortポジション建、またはlongポジション決済はこっちを使う))
    btc_jpy_bid_rate =  BigDecimal(JSON.parse(@response_read_ticker.body)['bid'])

    # 現在の売り注文の最安価格(つまり、こっちが買う(longポジション建、またはshortポジション決済はこっちを使う))
    btc_jpy_ask_rate =  BigDecimal(JSON.parse(@response_read_ticker.body)['ask'])

    timestamp =  JSON.parse(@response_read_ticker.body)['timestamp'].to_i
    btc_jpy_rate = (btc_jpy_bid_rate + btc_jpy_ask_rate)/2
    spread = (btc_jpy_ask_rate - btc_jpy_bid_rate).to_i
    @response_read_trades = @cc.read_trades
    @response_read_order_books = @cc.read_order_books

    #coincheckのレート取得
    @response_original_read_rate = @cc.original_read_rate

    if @go_spreadsheet_service && @go_spreadsheet_service.ws_info[:double_position][:data_time] != Time.at(timestamp).strftime("%Y-%m-%d %H:%M:%S")
      value_lines = []
      value_lines << Time.at(timestamp).strftime("%Y-%m-%d %H:%M:%S")
      value_lines << spread
      @go_spreadsheet_service.set_line(lines: value_lines,
                                       x_position: 1,
                                       y_position: @go_spreadsheet_service.ws_info[:double_position][:row_index],
                                       sheet_index: 0)
      @go_spreadsheet_service.ws_info[:double_position][:row_index] += 1
      @go_spreadsheet_service.ws_info[:double_position][:data_time] = Time.at(timestamp).strftime("%Y-%m-%d %H:%M:%S")
    end

    # ポジションの確認
    sleep 1 unless @running_back_test
    response = @cc.read_positions(status: "open")
    positions = JSON.parse(response.body)["data"]

    if positions.empty? && spread < 15
      # ポジション無し、かつスプレッドが15以下になったら両建て

      # 証拠金の確認
      sleep 1 unless @running_back_test
      response = @cc.read_leverage_balance
      margin_available = JSON.parse(response.body)['margin_available']['jpy']

      # ショートポジション
      order_amount = (margin_available * 0.4 / btc_jpy_bid_rate * 5).to_f.round(2) # 両建てで片方40%
      message = "#{Time.at(timestamp)}に#{btc_jpy_bid_rate.to_i}円でショート"
      @order_service.execute(order_type: "leverage_sell",
                             rate: btc_jpy_bid_rate.to_i,
                             amount: order_amount,
                             market_buy_amount: nil,
                             position_id: nil,
                             pair: "btc_jpy",
                             timestamp: timestamp,
                             message: message)

      # ロングポジション
      order_amount = (margin_available * 0.4 / btc_jpy_ask_rate * 5).to_f.round(2) # 両建てで片方40%
      message = "#{Time.at(timestamp)}に#{btc_jpy_ask_rate.to_i}円でロング"
      @order_service.execute(order_type: "leverage_buy",
                             rate: btc_jpy_ask_rate.to_i,
                             amount: order_amount,
                             market_buy_amount: nil,
                             position_id: nil,
                             pair: "btc_jpy",
                             timestamp: timestamp,
                             message: message)

    end

    unless positions.empty?
      if positions.size == 2
        # 両ポジション
        long_position = positions.select { |p| p["side"] == "buy" }.first
        short_position = positions.select { |p| p["side"] == "sell" }.first

        ## ロングポジション
        long_open_rate = long_position["open_rate"].to_f
        long_loss_cut_rate = (long_open_rate * 0.98).to_i
        if long_loss_cut_rate >= btc_jpy_bid_rate
          trade_type = "損切"
          message = "#{Time.at(timestamp)}に#{long_position['open_rate']}円のロングポジションを#{btc_jpy_bid_rate.to_i}で#{trade_type}"
          @order_service.execute(order_type: "close_long",
                                 rate: btc_jpy_bid_rate.to_i,
                                 amount: long_position["amount"],
                                 market_buy_amount: nil,
                                 position_id: long_position["id"],
                                 pair: "btc_jpy",
                                 timestamp: timestamp,
                                 message: message)
        end

        ## ショートポジション
        short_open_rate = short_position["open_rate"].to_f
        short_loss_cut_rate = (short_open_rate * 0.98).to_i
        if short_loss_cut_rate <= btc_jpy_ask_rate
          trade_type = "損切"
          binding.pry
          message = "#{Time.at(timestamp)}に#{positions[0]['open_rate']}円のショートポジションを#{btc_jpy_ask_rate.to_i}で#{trade_type}"
          @order_service.execute(order_type: "close_short",
                                 rate: btc_jpy_ask_rate.to_i,
                                 amount: positions.first["amount"],
                                 market_buy_amount: nil,
                                 position_id: positions.first["id"],
                                 pair: "btc_jpy",
                                 timestamp: timestamp,
                                 message: message)
        end
      else
        # 片方ポジション
        long_position = positions.select { |p| p["side"] == "buy" }.first
        short_position = positions.select { |p| p["side"] == "sell" }.first

        if long_position
          # ロングポジションが存在
          ## 現在の利益
          ## 利確ポイントを更新
          (btc_jpy_bid_rate - BigDecimal(long_position["open_rate"])) * BigDecimal(long_position["amount"])
          binding.pry
        else
          # ショートポジションが存在
          (BigDecimal(short_position["open_rate"]) - btc_jpy_ask_rate) * BigDecimal(short_position["amount"])
          binding.pry
        end

      end
    end



  end




end
