class MaxAndSinglePositionBollinger
  attr_accessor :response_read_ticker
  attr_accessor :response_read_trades
  attr_accessor :response_read_order_books
  attr_accessor :response_original_read_rate

  def initialize(coincheck_client:, bollinger_band_service:, logger:, running_back_test:, order_service:)
    @cc = coincheck_client
    @bollinger_band_service = bollinger_band_service
    @logger = logger
    @running_back_test = running_back_test
    @order_service = order_service

    @response_read_ticker
    @response_read_trades
    @response_read_order_books
    @response_original_read_rate
  end

  def execute
    # 現在のレート確認
    @response_read_ticker = @cc.read_ticker
    btc_jpy_bid_rate =  BigDecimal(JSON.parse(@response_read_ticker.body)['bid']) # 現在の買い注文の最高価格
    btc_jpy_ask_rate =  BigDecimal(JSON.parse(@response_read_ticker.body)['ask']) # 現在の売り注文の最安価格
    timestamp =  JSON.parse(@response_read_ticker.body)['timestamp'].to_i
    btc_jpy_rate = (btc_jpy_bid_rate + btc_jpy_ask_rate)/2

    @response_read_trades = @cc.read_trades
    @response_read_order_books = @cc.read_order_books

    #coincheckのレート取得
    @response_original_read_rate = @cc.original_read_rate

    @bollinger_band_service.set_values(rate: btc_jpy_rate,
                                      sell_rate: JSON.parse(@response_original_read_rate.body)["rate"],
                                      trades: JSON.parse(@response_read_trades.body),
                                      order_books: JSON.parse(@response_read_order_books.body),
                                      timestamp: timestamp)
    @logger.info(    "btc_jpy_bid_rate: #{btc_jpy_bid_rate.to_i}," +
                        "btc_jpy_ask_rate: #{btc_jpy_ask_rate.to_i}," +
                        "timestamp: #{Time.at(timestamp)}," +
                        "btc_jpy_rate: #{btc_jpy_rate.to_i}")

    result = @bollinger_band_service.check_signal_exec(rate: btc_jpy_rate,
                                                      timestamp: timestamp) # 試験的に

    # ポジションの確認
    sleep 1 unless @running_back_test
    response = @cc.read_positions(status: "open")
    positions = JSON.parse(response.body)["data"]
    @logger.info("positions: #{positions}")

    # 証拠金の確認
    sleep 1 unless @running_back_test
    response = @cc.read_leverage_balance
    margin_available = JSON.parse(response.body)['margin_available']['jpy']
    @logger.info("margin_available: #{margin_available}")

    @order_service.check_and_close_positions(positions, btc_jpy_bid_rate, btc_jpy_ask_rate, timestamp)

    if positions.empty?
      # ポジション無し
      if result == BollingerBandService::SHORT
        order_amount = (margin_available / btc_jpy_bid_rate * 5).to_f.round(2) # 全力
        message = "#{Time.at(timestamp)}に#{btc_jpy_bid_rate.to_i}円でショート"
        # ショートポジション
        @order_service.execute(order_type: "leverage_sell",
                              rate: btc_jpy_bid_rate.to_i,
                              amount: order_amount,
                              market_buy_amount: nil,
                              position_id: nil,
                              pair: "btc_jpy",
                              timestamp: timestamp,
                              message: message)

      elsif result == BollingerBandService::LONG
        order_amount = (margin_available / btc_jpy_bid_rate * 5).to_f.round(2)
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
    else
      open_rate = positions[0]["open_rate"]
      # 1.5%以上の利益で利確
      # -2.0%以下のロス発生で損切り
      if positions[0]["side"] == "buy"
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
          @order_service.execute(order_type: "close_long",
                                rate: btc_jpy_ask_rate.to_i,
                                amount: positions.first["amount"],
                                market_buy_amount: nil,
                                position_id: positions.first["id"],
                                pair: "btc_jpy",
                                timestamp: timestamp,
                                message: message)
        elsif positions[0]["side"] == "sell"
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
            @order_service.execute(order_type: "close_short",
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
    end
  end
end
