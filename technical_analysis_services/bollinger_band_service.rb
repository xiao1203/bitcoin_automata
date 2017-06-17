require 'bigdecimal'

class BollingerBandService
  # データ不足
  LACK_DATA = 0

  NON = 999
  LONG = 100
  MIDDLE_LONG = 101
  HIGH_LONG = 102
  SHORT = 200
  MIDDLE_SHORT = 201
  HIGH_SHORT = 202

  SELL_TREND = 300
  BUY_TREND = 301

  VALUES_BOX_SIZE = 200 # データセット格納数
  SIGNAL_HISTORY_BOX_SIZE = 100 # シグナル履歴格納数

  def initialize(chat_client = nil, bollinger_band_service_params = {}, go_spreadsheet_service = nil)
    @unit_rates = [] # 単位時間ごとのレート格納（例：1分足の場合、timestampのfirstとlastの差が60秒程度のもののグループ）
    @rates = [] # 単位時間ごとの平均値と最終時間を格納
    @values = [] # 最終成果物として、その時間の各値を格納
    @chat_client = chat_client

    @go_spreadsheet_service = go_spreadsheet_service
    # ヘッダの作成
    @go_spreadsheet_service.set_line(lines: %w(時間 移動平均 '+1σ '-1σ '+2σ '-2σ 中間値 販売レート 始値 終値 最高値 最安値 分散 標準偏差
                                                   expansion short_constrict long_constrict squeeze
                                                   trades_sell_amount_sum trades_buy_amount_sum trades_trend
                                                   order_books_asks_amount_sum order_books_bids_amount_sum order_bookss_trend),
                                     x_position: 1,
                                     y_position: 1,
                                     sheet_index: 0)

    @signal_histories = [] # シグナル発生履歴の格納

    # # google spread sheet制御変数
    # @row_index = 2
    # @data_time = nil

    # 遺伝子コードの仕様は
    # https://github.com/xiao1203/ga_trade_params_generator/blob/master/models/gene.rb#L42L52
    # https://github.com/xiao1203/ga_trade_params_generator/blob/master/modules/score_services/bollinger_band_service.rb#L26L65
    # に準拠
    unless bollinger_band_service_params.empty?
      # 足の単位時間
      @range_sec = bollinger_band_service_params[:range_sec]
      @range_sec = @range_sec <= 20 ? 20 : @range_sec

      # 外れ値判定の有意点
      # ここは2固定の方が良いかも
      @significant_point = bollinger_band_service_params[:significant_point]
      @significant_point = @significant_point <= 2 ? 2 : @significant_point

      # エクスパンション判定の標本数
      @expansion_check_range = bollinger_band_service_params[:expansion_check_range]
      @expansion_check_range = @expansion_check_range <= 3 ? 3 : @expansion_check_range

      # くびれチェック
      # 最大標本数（最小は4)
      @constrict_values_box_max_size = bollinger_band_service_params[:constrict_values_box_max_size]
      @constrict_values_box_max_size = @constrict_values_box_max_size <= 4 ? 4 : @constrict_values_box_max_size

      @balance_rate = bollinger_band_service_params[:balance_rate]
      @balance_rate = @balance_rate <= 120 ? 120 : @balance_rate
      @balance_rate = @balance_rate * 0.01

      short_range_start = bollinger_band_service_params[:short_range_start]
      short_range_end = bollinger_band_service_params[:short_range_end]
      short_range_start = short_range_start <= 0 ? 1 : short_range_start
      short_range_end = short_range_end <= 0 ? 3 : short_range_end
      @short_constrict_range = if short_range_start < short_range_end
                                 short_range_start..short_range_end
                               else
                                 short_range_end..short_range_start
                               end

      long_range_start = bollinger_band_service_params[:long_range_start]
      long_range_end = bollinger_band_service_params[:long_range_end]
      long_range_start = long_range_start <= 0 ? 1 : long_range_start
      long_range_end = long_range_end <= 0 ? 3 : long_range_end
      @long_constrict_range = if long_range_start < long_range_end
                                long_range_start..long_range_end
                              else
                                long_range_end..long_range_start
                              end

      params_msg = <<-EOS
足の単位時間: #{@range_sec}
外れ値判定の有意点: #{@significant_point}
エクスパンション判定の標本数: #{@expansion_check_range}
くびれチェック
@constrict_values_box_max_size: #{@constrict_values_box_max_size}
@balance_rate: #{@balance_rate}
@short_constrict_range: #{@short_constrict_range}
@long_constrict_range: #{@long_constrict_range}
      EOS

      puts params_msg
    else
      # 足の単位時間
      @range_sec = 60

      # 外れ値判定の有意点
      # ここは2固定の方が良いかも
      @significant_point = 2

      # エクスパンション判定の標本数
      @expansion_check_range = 5

      # くびれチェック
      # 最大標本数（最小は4)
      @constrict_values_box_max_size = 30
      @balance_rate = 1.4

      @short_constrict_range = 3...10
      @long_constrict_range = 15...30
    end

    # チェックを開始できる単位数(必ず2以上、通常は30)
    @target_count = [@short_constrict_range.max, @long_constrict_range.max, 30].max
  end

  def get_signal_history
    @signal_histories
  end

  def set_values(rate:, sell_rate:, trades:, order_books:, timestamp:)
    @unit_rates.push({rate: rate, timestamp: Time.at(timestamp)})

    if @unit_rates.last[:timestamp] - @unit_rates.first[:timestamp] > @range_sec
      # 最初と最後の格納データのtimestampが@range_secを初めて超えた時
      rates = @unit_rates.map{ |unit_rate| unit_rate[:rate] }
      start =  @unit_rates.first[:rate] # 始値
      last =  @unit_rates.last[:rate] # 終値
      @rates.push({
                      avg: rates.inject(:+)/rates.size, # 平均値
                      max: rates.max, # 高値
                      min: rates.min, # 安値
                      timestamp: @unit_rates.first[:timestamp]
                  })

      # 単位配列の初期化
      @unit_rates = []
    else
      # @range_sec分のデータが溜まっていないので後続処理には渡さない
      return
    end

    rates_size = @rates.size
    # puts "rates_size: #{rates_size}"
    # puts "rates_size >= TARGET_NUM: #{rates_size >= TARGET_NUM}"
    if rates_size >= @target_count
      # 計算に必要な情報が揃った
      @rates = @rates[(rates_size - @target_count)...rates_size]
      avg_ary = @rates.map{ |rate| rate[:avg] }

      # 高値
      max = @rates.map{ |rate| rate[:max] }.max

      # 安値
      min = @rates.map{ |rate| rate[:min] }.min

      result = get_standard_deviation(avg_ary)
      avg = result[:average] # 平均値
      sd = result[:standard_deviation] # 標準偏差
      var = result[:dispersion] # 分散値

      plus_one_std_dev = avg + sd
      minus_one_std_dev = avg - sd
      plus_two_std_dev = avg + (2 * sd)
      minus_two_std_dev = avg - (2 * sd)
      @values.push({
                       start: start.to_i,
                       last: last.to_i,
                       rate: (start.to_i + last.to_i)/2,
                       max: max.to_i,
                       min: min.to_i,
                       avg: avg.to_i,
                       var: var.to_i,
                       sd: sd.to_i,
                       plus_one_std_dev: plus_one_std_dev.to_i,
                       minus_one_std_dev: minus_one_std_dev.to_i,
                       plus_two_std_dev: plus_two_std_dev.to_i,
                       minus_two_std_dev: minus_two_std_dev.to_i,
                       timestamp: @rates.last[:timestamp],
                       trades: trades,
                       order_books: order_books,
                       sell_rate: sell_rate
                   })

      # VALUES_BOX_SIZE個保持
      values_size = @values.size
      if values_size > VALUES_BOX_SIZE
        @values = @values[(values_size - VALUES_BOX_SIZE)...values_size]
      end
    end
  end

  # 単純に現在のレートが
  def check_signal_exec(rate: ,timestamp:)
    # データ不足
    # puts "check_signal_exec @values: #{@values.size} "
    return LACK_DATA if @values.size < @target_count

    check_signal = check_signal_pattern(rate: rate)
    if @go_spreadsheet_service && @go_spreadsheet_service.ws_info[:bollinger_band_ws][:data_time] != @values.last[:timestamp].strftime("%Y-%m-%d %H:%M:%S")
      value_lines = []
      value_lines << @values.last[:timestamp].strftime("%Y-%m-%d %H:%M:%S")
      value_lines << @values.last[:avg]
      value_lines << @values.last[:plus_one_std_dev]
      value_lines << @values.last[:minus_one_std_dev]
      value_lines << @values.last[:plus_two_std_dev]
      value_lines << @values.last[:minus_two_std_dev]
      value_lines << @values.last[:rate]
      value_lines << @values.last[:sell_rate]
      value_lines << @values.last[:start]
      value_lines << @values.last[:last]
      value_lines << @values.last[:max]
      value_lines << @values.last[:min]
      value_lines << @values.last[:var]
      value_lines << @values.last[:sd]
      value_lines << check_signal[:expansion].to_s
      value_lines << check_signal[:short_constrict].to_s
      value_lines << check_signal[:long_constrict].to_s
      value_lines << check_signal[:squeeze].to_s

      trades_sell_amount_sum = @values.last[:trades].select { |trade| trade["order_type"] == "sell"}.map{ |t| BigDecimal(t["amount"]) }.inject(:+).to_f
      trades_buy_amount_sum = @values.last[:trades].select { |trade| trade["order_type"] == "buy"}.map{ |t| BigDecimal(t["amount"]) }.inject(:+).to_f
      value_lines << trades_sell_amount_sum
      value_lines << trades_buy_amount_sum
      value_lines << if trades_sell_amount_sum > trades_buy_amount_sum
                       "売りトレード優勢"
                     else
                       "買いトレード優勢"
                     end

      order_books_asks_amount_sum = @values.last[:order_books]["asks"].map { |o| BigDecimal(o[1]) }.inject(:+).to_f
      order_books_bids_amount_sum = @values.last[:order_books]["bids"].map { |o| BigDecimal(o[1]) }.inject(:+).to_f
      value_lines << order_books_asks_amount_sum
      value_lines << order_books_bids_amount_sum
      value_lines << if order_books_asks_amount_sum > order_books_bids_amount_sum
                       "買い優勢"
                     else
                       "売り優勢"
                     end

      @go_spreadsheet_service.set_line(lines: value_lines,
                                       x_position: 1,
                                       y_position: @go_spreadsheet_service.ws_info[:bollinger_band_ws][:row_index],
                                       sheet_index: 0)
      @go_spreadsheet_service.ws_info[:bollinger_band_ws][:row_index] += 1
      @go_spreadsheet_service.ws_info[:bollinger_band_ws][:data_time] = @values.last[:timestamp].strftime("%Y-%m-%d %H:%M:%S")
    end

    @signal_histories.push({
                             signal: check_signal,
                             trades_sell_amount_sum: trades_sell_amount_sum,
                             trades_buy_amount_sum: trades_buy_amount_sum,
                             order_books_asks_amount_sum: order_books_asks_amount_sum,
                             order_books_bids_amount_sum: order_books_bids_amount_sum,
                             rate: rate.to_f,
                             value: @values.last,
                             timestamp: timestamp,
                             time: Time.now
                         })

    # 過去のシグナル（SIGNAL_HISTORY_BOX_SIZE個保持）
    signal_history_size = @signal_histories.size
    if signal_history_size > SIGNAL_HISTORY_BOX_SIZE
      @signal_histories = @signal_histories[(signal_history_size - SIGNAL_HISTORY_BOX_SIZE)...signal_history_size]
    end

    return trade_signal
  end

  private

  # シグナル判定
  def check_signal_pattern(rate:)
    signal_result = {}

    # スクイーズ
    signal_result[:squeeze] = is_squeeze?
    # エクスパンション & バンドウォーク
    signal_result[:expansion] = is_expansion?
    # くびれ形成(短期レンジ、長期レンジを見る)
    signal_result[:short_constrict] = is_constrict?(range: @short_constrict_range, balance_late: @balance_rate)
    signal_result[:long_constrict] = is_constrict?(range: @long_constrict_range, balance_late: @balance_rate )
    # W-ボトム
    signal_result[:w_bottom] = is_w_bottom?
    # M-トップ
    signal_result[:m_top] = is_m_top?

    signal_result
  end

  def trade_signal
    signal_histories = @signal_histories.uniq{ |hs| hs[:timestamp] }
    signal_history = signal_histories.last
    values = @values.last

    return NON if signal_histories.size < 3

    trades_sell_amount_sum = signal_history[:trades_sell_amount_sum] || @values.last[:trades].select { |trade| trade["order_type"] == "sell"}.map{ |t| BigDecimal(t["amount"]) }.inject(:+).to_f
    trades_buy_amount_sum = signal_history[:trades_buy_amount_sum] || @values.last[:trades].select { |trade| trade["order_type"] == "buy"}.map{ |t| BigDecimal(t["amount"]) }.inject(:+).to_f
    trades_amount_sum_trend = if trades_sell_amount_sum > trades_buy_amount_sum
                                SELL_TREND
                              else
                                BUY_TREND
                              end
    order_books_asks_amount_sum = signal_history[:order_books_asks_amount_sum] || @values.last[:order_books]["asks"].map { |o| BigDecimal(o[1]) }.inject(:+).to_f
    order_books_bids_amount_sum = signal_history[:order_books_bids_amount_sum] || @values.last[:order_books]["bids"].map { |o| BigDecimal(o[1]) }.inject(:+).to_f
    order_books_amount_sum_trend = if order_books_asks_amount_sum > order_books_bids_amount_sum
                                     BUY_TREND
                                   else
                                     SELL_TREND
                                   end

    # 直近３つの中間値が -1.5σ 〜 移動平均 のところにいる場合、売りトレンド(Short)は無効
    # 直近３つの中間値が 移動平均 〜 1.5σ のところにいる場合、買いトレンド(Long)は、無効
    last_3 = signal_histories[signal_histories.size - 3]
    last_2 = signal_histories[signal_histories.size - 2]
    last_1 = signal_histories[signal_histories.size - 1]

    average_rate = (last_3[:rate] + last_2[:rate] + last_1[:rate])/3
    plus_1_5_std_dev = (signal_history[:value][:plus_one_std_dev] + signal_history[:value][:plus_two_std_dev])/2
    minus_1_5_std_dev = (signal_history[:value][:minus_one_std_dev] + signal_history[:value][:minus_two_std_dev])/2

    long_range_signal = plus_1_5_std_dev > average_rate && signal_history[:value][:avg] < average_rate
    short_range_signal = minus_1_5_std_dev < average_rate && signal_history[:value][:avg] > average_rate

    if signal_history[:signal][:expansion] || signal_history[:signal][:short_constrict] || signal_history[:signal][:long_constrict]
      if trades_amount_sum_trend == SELL_TREND && order_books_amount_sum_trend == SELL_TREND && short_range_signal
        return SHORT
      elsif trades_amount_sum_trend == BUY_TREND && order_books_amount_sum_trend == BUY_TREND && long_range_signal
        return LONG
      end
    end

    # if is_trend_pattern_1?(signal_history)
    #   if values[:max] > values[:plus_two_std_dev]
    #     # 最高値が+2σを上回っている
    #     binding.pry
    #     return LONG
    #   elsif values[:min] < values[:minus_two_std_dev]
    #     # 最安値が-2σを上回っている
    #     binding.pry
    #     return SHORT
    #   end
    # end
    #
    # # 仲値が+2σを上回っている状態が続き、下落傾向が発生
    # if is_trend_pattern_2?
    #   return LONG
    # end

    NON
  end

  # スクイーズ状態の判定
  ## 判定基準
  ## 移動平均と「+1σ、+2σ、-1σ、-2σ」の間隔つまり、各評価軸の標準偏差において、最初と最後で大きな変動がない状態
  ## 細かい増減はあるが、明確なトレンドが見えてない状態
  ## TODO 暫定として直近5個のレンジ範囲内で外れ値がないことを条件とする
  def is_squeeze?
    # 最新の標準偏差が過去5本ぶんから外れ値がないことを判定する
    size = @values.size
    sds = @values[(size - @expansion_check_range)...size].map{ |value| value[:sd] }

    res = check_outlier(ary: sds, val: sds.last, significant: @significant_point)
    res[:result] == false
  end

  # エクスパンション状態の判定
  ## 判定基準
  ## 移動平均と「+1σ、+2σ、-1σ、-2σ」の間隔つまり、各評価軸の標準偏差において、最初と最後で大きな変動が発生した状態
  ## 明確なトレンドが発生する可能性が高い
  ## TODO だましへの対処が必要。突発的に上がっても、そこが最高値、または最低値になり、これ以上トレンド通りに推移しないケースがある。
  ## その場合、ただの高掴みになってしまう
  def is_expansion?
    # 最新の標準偏差が過去5本ぶんから外れ値であるかを判定する
    size = @values.size
    sds = @values[(size - @expansion_check_range)...size].map{ |value| value[:sd] }
    res = check_outlier(ary: sds, val: sds.last, significant: @significant_point)

    return false unless res[:result]

    # バンドウォーク状態の判定
    if @values.last[:min] < @values.last[:plus_two_std_dev] ||
        @values.last[:max] < @values.last[:plus_two_std_dev] ||
        @values.last[:rate] < @values.last[:plus_two_std_dev]
      # +2σ上を推移？
      true
    elsif @values.last[:min] > @values.last[:minus_two_std_dev] ||
        @values.last[:max] > @values.last[:minus_two_std_dev] ||
        @values.last[:rate] > @values.last[:minus_two_std_dev]
      # -2σ上を推移？
      true
    else
      false
    end
  end

  # ボリンジャーバンドに「くびれ」が形成されていることを確認
  # 標本グループを2等分して最初と最後の最大値(①)と、標本全体の最小値(②)を比較。
  # 標準偏差の比率が ① : ② = balance_late : 1
  # になるかを確認する
  def is_constrict?(range:, balance_late:)
    size = @values.size
    # 最大標本数
    range.each do |count|
      values = @values[(size - count)...size]
      # 標本中の最小標準偏差
      min_sd = values.map{ |value| value[:sd] }.min

      return false if min_sd.zero?

      # 標本を２分割し、それぞれの最大標準偏差を取得（countが奇数の時、取りこぼしが発生するけど、一旦これで）
      first_group = values[0...(count/2).to_i]
      last_group = values[(count/2).to_i...count]
      first_group_max = first_group.map{ |value| value[:sd] }.max
      last_group_max = last_group.map{ |value| value[:sd] }.max

      return true if first_group_max.to_f/min_sd > balance_late && last_group_max.to_f/min_sd > balance_late
    end

    false
  end

  #TODO 一旦保留
  def is_w_bottom?
    false
  end

  #TODO 一旦保留
  def is_m_top?
    false
  end

  # 配列を引数にわたし、標準偏差の計算を行う
  # 戻り値は標準偏差と平均（他に増えても良いようにHashで返却）
  def get_standard_deviation(ary)
    # 平均値
    avg = BigDecimal(ary.inject(:+))/ary.size

    # 分散値
    var = ary.reduce(0) { |a,b| a + (b - avg) ** 2 } / ary.size

    # 標準偏差
    sd = Math.sqrt(var)

    { standard_deviation: sd, average: avg, dispersion: var}
  end

  # 外れ値か否かを判定
  # 引数
  ## ary 標本が格納された配列
  ## val 判定対象
  ## range 標本数
  ## significant 有意値
  #
  # 戻り値
  ## result 計算結果を有意値と比較し他結果
  ## outlier 計算結果
  # FIXME 厳密に判定する為にはスミルノフ・グラブス検定がしたいが計算がよくわからん。。。orz
  def check_outlier(ary:, val:, range: @expansion_check_range, significant: @significant_point)
    ary = ary[(ary.size - range)...ary.size]
    result = get_standard_deviation(ary)
    avg = result[:average] # 平均値
    sd = result[:standard_deviation] # 標準偏差

    outlier = ((val - avg)/sd).abs

    {result: outlier > significant, outlier: outlier}
  end

  # 長期スパンでみてくびれが発生し、expansion状態になったので、反転の兆しがある
  def is_trend_pattern_1?(signal_history)
    return false if signal_history[:signal][:squeeze]
    return false unless signal_history[:signal][:expansion]
    return false unless signal_history[:signal][:short_constrict]
    return false if signal_history[:signal][:long_constrict]

    true
  end

  # 2017-05-21 06:20:18
  # 10件程度遡り+2σを仲値が上回っている
  # 狙いがピンポイントすぎるので、あまり当たらなければ見直し
  def is_trend_pattern_2?
    # 10件程度遡り+2σを仲値が上回っている
    values = @values[(@values.size - 10)...@values.size]
    result = []
    values.each do |hs|
      if hs[:rate] > hs[:plus_two_std_dev]
        result.push(hs[:rate])
      else
        break
      end
    end

    return false if result.size < 3

    #最初から最後の一個前までは上昇傾向、最後の一個で反転
    tmp_result = result[0...result.size - 1]
    last = result.last
    tmp_result.each_with_index do |res, index|
      next if index.zero?
      unless res > tmp_result[index - 1]
        return false
      end
    end
    last < tmp_result.last
  end
end
