class OrderService
  def initialize(coincheck_client, logger, chat_service, order_execute, running_back_test)
    @coincheck_client = coincheck_client
    @logger = logger
    @chat_service = chat_service
    @order_execute = order_execute
    @running_back_test = running_back_test
  end

  def execute(order_type:, rate:, amount:, market_buy_amount: nil, position_id: nil, pair: "btc_jpy", timestamp:, message:)
    if @order_execute
      @coincheck_client.create_orders(order_type: order_type,
                                      rate: rate,
                                      amount: amount,
                                      market_buy_amount: market_buy_amount,
                                      position_id: position_id,
                                      pair: pair)

      @logger.info(    "create_orser# " +
                           "order_type: #{order_type}, " +
                           "rate: #{rate}" +
                           "amount: #{amount}" +
                           "market_buy_amount: #{market_buy_amount}" +
                           "position_id: #{position_id}" +
                           "pair: #{pair}")
    end
    puts message
    @chat_service.send_message(message: message)
  end

  # ショートポジション開始発注
  def set_start_short_position(margin_available, positions, btc_jpy_bid_rate, btc_jpy_ask_rate, timestamp)
    # ポジションを持っていなかったら証拠金の40%を目安にしたポジションを立てる
    sleep 1 unless @running_back_test
    if positions.empty?
      order_amount = (((margin_available * 0.4) / btc_jpy_bid_rate) * 5).to_f.round(2)
      message = "#{Time.at(timestamp)}に#{btc_jpy_bid_rate.to_i}円、#{order_amount}BTCでショート"
      # ショートポジション
      execute(order_type: "leverage_sell",
              rate: btc_jpy_bid_rate.to_i,
              amount: order_amount,
              market_buy_amount: nil,
              position_id: nil,
              pair: "btc_jpy",
              timestamp: timestamp,
              message: message)
    else
      long_positions = positions.select { |p| p["side"] == "buy" && p["status"] == "open" }
      unless long_positions.empty?
        # ロングポジションがあったら決済
        long_positions.each do |long_position|
          open_value = BigDecimal(long_position["open_rate"]) * BigDecimal(long_position["amount"])
          close_value = btc_jpy_ask_rate * BigDecimal(long_position["amount"])

          if open_value < close_value
            trade_type = "利確"
            profit = (close_value - open_value).to_i
          else
            trade_type = "損切"
            profit = (open_value - close_value).to_i
          end
          message = "#{Time.at(timestamp)}に#{positions[0]['open_rate']}円のロングポジションを#{btc_jpy_ask_rate.to_i}で#{trade_type}。#{profit}円の#{trade_type}発生"
          execute(order_type: "close_long",
                  rate: btc_jpy_ask_rate.to_i,
                  amount: long_position["amount"],
                  market_buy_amount: nil,
                  position_id: long_position["id"],
                  pair: "btc_jpy",
                  timestamp: timestamp,
                  message: message)
        end

        order_amount = (((margin_available * 0.4) / btc_jpy_bid_rate) * 5).to_f.round(2)
        message = "#{Time.at(timestamp)}に#{btc_jpy_bid_rate.to_i}円、#{order_amount}BTCでショート"
        # ショートポジション
        execute(order_type: "leverage_sell",
                rate: btc_jpy_bid_rate.to_i,
                amount: order_amount,
                market_buy_amount: nil,
                position_id: nil,
                pair: "btc_jpy",
                timestamp: timestamp,
                message: message)
      else
        #現ポジションの方向が合っていたらポジション買い増し
        short_positions = positions.select { |p| p["side"] == "sell" && p["status"] == "open" }
        if short_positions.all? { |p| BigDecimal(p["open_rate"]) * 0.99 > btc_jpy_bid_rate }
          minimum_amount = BigDecimal(short_positions.min { |p| BigDecimal(p["amount"]) }["amount"])
          # 現在の証拠金と照らし合わせてminimum_amount/2を取れたらとる
          execute(order_type: "leverage_sell",
                  rate: btc_jpy_bid_rate.to_i,
                  amount: minimum_amount/2,
                  market_buy_amount: nil,
                  position_id: nil,
                  pair: "btc_jpy",
                  timestamp: timestamp,
                  message: message)
        end
      end
    end
  end

  # ロングポジションの開始発注
  def set_start_long_position(margin_available, positions, btc_jpy_ask_rate, btc_jpy_bid_rate, timestamp)
    sleep 1 unless @running_back_test
    if positions.empty?
      order_amount = (((margin_available * 0.4) / btc_jpy_ask_rate) * 5).to_f.round(2)
      message = "#{Time.at(timestamp)}に#{btc_jpy_ask_rate.to_i}円、#{order_amount}BTCでロング"
      # ロングポジション
      execute(order_type: "leverage_buy",
              rate: btc_jpy_ask_rate.to_i,
              amount: order_amount,
              market_buy_amount: nil,
              position_id: nil,
              pair: "btc_jpy",
              timestamp: timestamp,
              message: message)
    else
      short_positions = positions.select { |p| p["side"] == "sell" && p["status"] == "open" }
      unless short_positions.empty?
        # ショートポジションがあったら決済
        short_positions.each do |short_position|
          open_value = BigDecimal(short_position["open_rate"]) * BigDecimal(short_position["amount"])
          close_value = btc_jpy_bid_rate * BigDecimal(short_position["amount"])

          if open_value > close_value
            trade_type = "利確"
            profit = (open_value - close_value).to_i
          else
            trade_type = "損切"
            profit = (close_value - open_value).to_i
          end
          message = "#{Time.at(timestamp)}に#{positions[0]['open_rate']}円のショートポジションを#{btc_jpy_bid_rate.to_i}で#{trade_type}。#{profit}円の#{trade_type}発生"
          execute(order_type: "close_short",
                  rate: btc_jpy_ask_rate.to_i,
                  amount: short_position["amount"],
                  market_buy_amount: nil,
                  position_id: short_position["id"],
                  pair: "btc_jpy",
                  timestamp: timestamp,
                  message: message)
        end

        # ロングポジションの設定
        order_amount = (((margin_available * 0.4) / btc_jpy_ask_rate) * 5).to_f.round(2)
        message = "#{Time.at(timestamp)}に#{btc_jpy_ask_rate.to_i}円、#{order_amount}BTCでロング"
        # ロングポジション
        execute(order_type: "leverage_buy",
                rate: btc_jpy_ask_rate.to_i,
                amount: order_amount,
                market_buy_amount: nil,
                position_id: nil,
                pair: "btc_jpy",
                timestamp: timestamp,
                message: message)
      else
        #現ポジションの方向が合っていたらポジション買い増し
        long_positions = positions.select { |p| p["side"] == "buy" && p["status"] == "open" }
        if long_positions.all? { |p| BigDecimal(p["open_rate"]) * 1.01 < btc_jpy_ask_rate }
          minimum_amount = BigDecimal(long_positions.min { |p| BigDecimal(p["amount"]) }["amount"])
          # 現在の証拠金と照らし合わせてminimum_amount/2を取れたらとる
          execute(order_type: "leverage_buy",
                  rate: btc_jpy_ask_rate.to_i,
                  amount: minimum_amount/2,
                  market_buy_amount: nil,
                  position_id: nil,
                  pair: "btc_jpy",
                  timestamp: timestamp,
                  message: message)
        end
      end
    end
  end


  def check_and_close_positions(positions, btc_jpy_bid_rate, btc_jpy_ask_rate, timestamp)
    # btc_jpy_bid_rate 現在の買い注文の最高価格
    # btc_jpy_ask_rate 現在の売り注文の最安価格
    return if positions.empty?

    # 2%の利益が取れていたら決済注文実施
    positions.each do |position|
      if position["side"] == "buy"
        # ロングポジション
        next unless BigDecimal(position["open_rate"]) * 1.003 < btc_jpy_ask_rate

        open_value = BigDecimal(position["open_rate"]) * BigDecimal(position["amount"])
        close_value = btc_jpy_ask_rate * BigDecimal(position["amount"])

        if open_value < close_value
          trade_type = "利確"
          puts "利確処理ヒット"
          profit = (close_value - open_value).to_i
        else
          trade_type = "損切"
          profit = (open_value - close_value).to_i
        end
        message = "#{Time.at(timestamp)}に#{positions[0]['open_rate']}円のロングポジションを#{btc_jpy_ask_rate.to_i}で#{trade_type}。#{profit}円の#{trade_type}発生"
        execute(order_type: "close_long",
                rate: btc_jpy_ask_rate.to_i,
                amount: position["amount"],
                market_buy_amount: nil,
                position_id: position["id"],
                pair: "btc_jpy",
                timestamp: timestamp,
                message: message)

      else
        # ショートポジション
        next unless BigDecimal(position["open_rate"]) * 0.997 > btc_jpy_bid_rate

        open_value = BigDecimal(position["open_rate"]) * BigDecimal(position["amount"])
        close_value = btc_jpy_bid_rate * BigDecimal(position["amount"])

        if open_value > close_value
          trade_type = "利確"
          puts "利確処理ヒット"
          profit = (open_value - close_value).to_i
        else
          trade_type = "損切"
          profit = (close_value - open_value).to_i
        end
        message = "#{Time.at(timestamp)}に#{positions[0]['open_rate']}円のショートポジションを#{btc_jpy_bid_rate.to_i}で#{trade_type}。#{profit}円の#{trade_type}発生"
        execute(order_type: "close_short",
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
end
