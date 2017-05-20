class BollingerBandService

  # データ不足
  LACK_DATA = 0

  SQUEEZE = 1
  EXPANSION = 2
  WALKING_BAND = 3
  W_BOTTOM = 4
  M_TOP = 5

  LONG = 100
  SHORT = 101

  # 足の単位時間
  RANGE_SEC = 60

  # 単位数(必ず2以上、通常は10)
  TARGET_NUM = 3

  VALUES_BOX_SIZE = 200 # データセット格納数
  SIGNAL_HISTORY_BOX_SIZE = 20 # シグナル履歴格納数


  def initialize(chat_client = nil)
    @unit_rates = [] # 単位時間ごとのレート格納（例：1分足の場合、timestampのfirstとlastの差が60秒程度のもののグループ）
    @rates = [] # 単位時間ごとの平均値と最終時間を格納
    @values = [] # 最終成果物として、その時間の各値を格納
    @chat_client = chat_client

    @signal_history = [] # シグナル発生履歴の格納

  end

  def set_rate(rate:, timestamp:)
    @unit_rates.push({rate: rate, timestamp: Time.at(timestamp)})

    if @unit_rates.last[:timestamp] - @unit_rates.first[:timestamp] > RANGE_SEC
      # 最初と最後の格納データのtimestampがRANGE_SECを初めて超えた時
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
      # RANGE_SEC分のデータが溜まっていないので後続処理には渡さない
      return
    end

    rates_size = @rates.size
    if rates_size >= TARGET_NUM
      # 計算に必要な情報が揃った
      @rates = @rates[(rates_size - TARGET_NUM)...rates_size]
      avg_ary = @rates.map{ |rate| rate[:avg] }

      # 高値
      max = @rates.map{ |rate| rate[:max] }.max

      # 安値
      min = @rates.map{ |rate| rate[:min] }.min

      # 平均値
      avg = avg_ary.inject(:+)/TARGET_NUM

      # 分散値
      var = avg_ary.reduce(0) { |a,b| a + (b - avg) ** 2 } / (TARGET_NUM - 1)

      # 標準偏差
      sd = Math.sqrt(var)

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
                       plus_one_std_dev: plus_one_std_dev.to_i,
                       minus_one_std_dev: minus_one_std_dev.to_i,
                       plus_two_std_dev: plus_two_std_dev.to_i,
                       minus_two_std_dev: minus_two_std_dev.to_i,
                       timestamp: @rates.last[:timestamp]
                   })

      # VALUES_BOX_SIZE個保持
      values_size = @values.size
      if values_size > VALUES_BOX_SIZE
        @values = @values[(values_size - VALUES_BOX_SIZE)...values_size]
      end
    end
  end

  # 単純に現在のレートが
  def check_signal_exec(rate)
    # データ不足
    return LACK_DATA if @values.size < TARGET_NUM
    return @values.last.to_json

    signal = check_signal_pattern(rate)

    if signal
      @signal_history.push({
                               signal: signal,
                               time: Time.now
                           })

      # 過去のシグナル（SIGNAL_HISTORY_BOX_SIZE個保持）
      signal_history_size = @signal_history.size
      if signal_history_size > SIGNAL_HISTORY_BOX_SIZE
        @signal_history = @signal_history[(signal_history_size - SIGNAL_HISTORY_BOX_SIZE)...signal_history_size]
      end

      return trade_signal
    end

  end

  private

  # シグナル判定
  def check_signal_pattern(rate)
    # スクイーズ
    return SQUEEZE if is_squeeze?

    # エクスパンション
    return EXPANSION if is_expansion?

    # バンドウォーク
    return EXPANSION if is_walking_band?

    # W-ボトム
    return W_BOTTOM if is_w_bottom?

    # M-トップ
    return M_TOP if is_m_top?
  end

  def trade_signal
    LONG
    SHORT
  end

  # スクイーズ状態の判定
  ## 判定基準
  ## 移動平均と「+1σ、+2σ、-1σ、-2σ」の間隔に大きな変動がない状態
  ## 細かい増減はあるが、明確なトレンドが見えてない状態
  def is_squeeze?

  end
end