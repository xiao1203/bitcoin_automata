class OrderService
  def initialize(coincheck_client, logger, chat_service, order_execute)
    @coincheck_client = coincheck_client
    @logger = logger
    @chat_service = chat_service
    @order_execute = order_execute
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


end