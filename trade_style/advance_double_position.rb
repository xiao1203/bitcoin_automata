# なんらかのシグナルで単方向ポジションをとり余力の40%のポジションでとり、
# もし、規定量の損失が発生したら、逆張りを同じポジションの分だけとる
# もし、利益が出てきたら利確ポイントを移動させながら利益最大化を目指す

class AdvanceDoublePosition
  attr_accessor :response_read_ticker
  attr_accessor :response_read_trades
  attr_accessor :response_read_order_books
  attr_accessor :response_original_read_rate

  def initialize(coincheck_client: nil,
                 logger: nil,
                 running_back_test: nil,
                 order_service: nil,
                 go_spreadsheet_service: nil,
                 parameter_hash: {},
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

    @loss_value = 0
    @gain_rate = 0

    unless parameter_hash.empty?
      # 10 〜 31
      @spread_range = parameter_hash[:spread_range]

      # 0.999 〜 0.990 (0.001...0.010)
      @long_loss_cut_rate = 1.000 - (parameter_hash[:long_loss_cut_rate] * 0.001)

      # 1.001 〜 1.01 (0.001...0.010)
      @short_loss_cut_rate = 1.000 + (parameter_hash[:short_loss_cut_rate] * 0.001)

      # 1.001 〜 1.01 (0.001...0.010)
      @profit_set_rate = 1.000 + (parameter_hash[:profit_set_rate] * 0.001)
    else
      @spread_range = 10
      @long_loss_cut_rate = 0.998
      @short_loss_cut_rate = 1.002
      @profit_set_rate = 1.001

      @long_position_replace_rate = 0.999
      @short_position_replace_rate = 1.001
    end
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

    # ポジションの確認
    sleep 1 unless @running_back_test
    response = @cc.read_positions(status: "open")
    positions = JSON.parse(response.body)["data"]

    if positions.empty?
      # ポジションなし
      # 証拠金の確認
      sleep 1 unless @running_back_test
      response = @cc.read_leverage_balance
      margin_available = JSON.parse(response.body)['margin_available']['jpy']

      if long_signal?
        # ロングポジション
        order_amount = (margin_available * 0.4 / btc_jpy_ask_rate * 5).to_f.round(2) # 両建てで片方40%
        message = "#{Time.at(timestamp)}に#{btc_jpy_ask_rate.to_i}円で#{order_amount}分をロング"
        @order_service.execute(order_type: "leverage_buy",
                               rate: btc_jpy_ask_rate.to_i,
                               amount: order_amount,
                               market_buy_amount: nil,
                               position_id: nil,
                               pair: "btc_jpy",
                               timestamp: timestamp,
                               message: message)
      elsif short_signal?
        # ショートポジション
        order_amount = (margin_available * 0.4 / btc_jpy_bid_rate * 5).to_f.round(2) # 両建てで片方40%
        message = "#{Time.at(timestamp)}に#{btc_jpy_bid_rate.to_i}円で#{order_amount}分をショート"
        @order_service.execute(order_type: "leverage_sell",
                               rate: btc_jpy_bid_rate.to_i,
                               amount: order_amount,
                               market_buy_amount: nil,
                               position_id: nil,
                               pair: "btc_jpy",
                               timestamp: timestamp,
                               message: message)
      end
    else
      # ポジションあり
      long_position = positions.select { |p| p["side"] == "buy" }.first
      short_position = positions.select { |p| p["side"] == "sell" }.first

      if positions.size == 2
        # 両建てになっている
        # TODO 両建てして、損失幅をある程度（スプレッドによって多少の変動あり）固定化した後の対処が不透明
        # このあたりの戦略をしっかり練らないと損切りを繰り返すだけになってしまう

      elsif positions.size == 1
        if long_position
          ## ロングポジションあり
          long_open_rate = long_position["open_rate"].to_f
          long_loss_cut_rate = (long_open_rate * @long_loss_cut_rate).to_i
          long_position_amount = long_position["amount"]

          if long_loss_cut_rate >= btc_jpy_bid_rate
            # Longポジションが規定の含み損を抱えてしまったので、逆張りで同じ数量のshortポジションを作成
            message = "#{Time.at(timestamp)}に#{btc_jpy_bid_rate.to_i}円で#{long_position_amount}分をショート"
            @order_service.execute(order_type: "leverage_sell",
                                   rate: btc_jpy_bid_rate.to_i,
                                   amount: long_position_amount,
                                   market_buy_amount: nil,
                                   position_id: nil,
                                   pair: "btc_jpy",
                                   timestamp: timestamp,
                                   message: message)
          end

          if !@gain_rate.zero? && @gain_rate > btc_jpy_bid_rate
            # 利益があるうちに決済
            trade_type = "利確"
            profit_value = ((btc_jpy_bid_rate - BigDecimal(long_position["open_rate"])) * BigDecimal(long_position["amount"])).to_i

            message = "#{Time.at(timestamp)}に#{long_position['open_rate']}円のロングポジションを#{btc_jpy_bid_rate.to_i}で#{trade_type}。#{profit_value}円"
            @order_service.execute(order_type: "close_long",
                                   rate: btc_jpy_bid_rate.to_i,
                                   amount: long_position["amount"],
                                   market_buy_amount: nil,
                                   position_id: long_position["id"],
                                   pair: "btc_jpy",
                                   timestamp: timestamp,
                                   message: message)
            @gain_rate = 0
          elsif (long_open_rate * @profit_set_rate) < btc_jpy_bid_rate
            ## 規定の含み益が発生
            ## 利確ポイントを更新
            @gain_rate = btc_jpy_bid_rate
          end
        else
          short_open_rate = short_position["open_rate"].to_f
          short_loss_cut_rate = (short_open_rate * @short_loss_cut_rate).to_i
          short_position_amount = short_position["amount"]

          if short_loss_cut_rate <= btc_jpy_ask_rate
            # shortポジションが規定の含み損を抱えてしまったので、逆張りで同じ数量のLongポジションを作成
            message = "#{Time.at(timestamp)}に#{btc_jpy_ask_rate.to_i}円で#{short_position_amount}分をロング"
            @order_service.execute(order_type: "leverage_buy",
                                   rate: btc_jpy_ask_rate.to_i,
                                   amount: short_position_amount,
                                   market_buy_amount: nil,
                                   position_id: nil,
                                   pair: "btc_jpy",
                                   timestamp: timestamp,
                                   message: message)
          end

          if !@gain_rate.zero? && @gain_rate < btc_jpy_ask_rate
            # 利益があるうちに決済
            trade_type = "利確"
            profit_value = ((BigDecimal(short_position["open_rate"]) - btc_jpy_ask_rate) * BigDecimal(short_position["amount"])).to_i

            message = "#{Time.at(timestamp)}に#{short_position['open_rate']}円のショートポジションを#{btc_jpy_ask_rate.to_i}で#{trade_type}。#{profit_value}円"
            @order_service.execute(order_type: "close_short",
                                   rate: btc_jpy_ask_rate.to_i,
                                   amount: short_position["amount"],
                                   market_buy_amount: nil,
                                   position_id: short_position["id"],
                                   pair: "btc_jpy",
                                   timestamp: timestamp,
                                   message: message)
            @gain_rate = 0
          elsif (short_open_rate * @profit_set_rate) > btc_jpy_ask_rate
            ## 規定の含み益が発生
            ## 利確ポイントを更新
            @gain_rate = btc_jpy_ask_rate
          end
        end

      else
        # 想定外のケース
        binding.pry
      end
    end
  rescue => e
    binding.pry
  end





  private

  # ロングシグナル発生確認
  def long_signal?
    [true, false, false, false].sample
  end

  # ショートシグナル発生確認
  def short_signal?
    [true, false, false, false].sample
  end


end