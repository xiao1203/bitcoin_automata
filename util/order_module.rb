module OrderModule
  def create_orders(coincheck_client:, logger:, chat_service:, order_type:, rate:, amount:, market_buy_amount: nil, position_id: nil, pair: "btc_jpy", timestamp:, message:)
    response = coincheck_client.create_orders(order_type: order_type,
                                              rate: rate,
                                              amount: amount,
                                              market_buy_amount: market_buy_amount,
                                              position_id: position_id,
                                              pair: pair)
    logger.info(    "create_orser# " +
                        "order_type: #{order_type}, " +
                        "rate: #{rate}" +
                        "amount: #{amount}" +
                        "market_buy_amount: #{market_buy_amount}" +
                        "position_id: #{position_id}" +
                        "pair: #{pair}")

    puts message
    chat_service.send_message(message: message)
  end


end