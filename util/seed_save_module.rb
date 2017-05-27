require 'csv'
require "openssl"

module SeedSaveModule

  def save_seed_csv(coincheck_client, path, id, btc_jpy_https)
    threads = []
    threads << generate_saving_process do
      # ticker
      ticker_seed_save(coincheck_client, path, id)
    end

    threads << generate_saving_process do
      # trade
      trade_seed_save(coincheck_client, path, id)
    end

    threads << generate_saving_process do
      # order_book
      order_book_seed_save(coincheck_client, path, id)
    end

    threads << generate_saving_process do
      # rate
      rate_seed_save(btc_jpy_https, path, id)
    end
  end

  def generate_saving_process
    thread = Thread.new do
      begin
        yield
      rescue => e
        puts "エラー：#{e}"
      end
    end

    thread
  end


  def ticker_seed_save(coincheck_client, path, id)
    CSV.open("#{path}/ticker.csv",'a') do |test|
      test << %w(id json_body trade_time_int)
      begin
        retries = 0
        response = coincheck_client.read_ticker
        now_time_int = Time.now.strftime("%Y%m%d%H%M%S").to_i
      rescue => e
        retries += 1
        if retries < 3
          retry # <-- Jumps to begin
        else
          # Error handling code, e.g.
          puts "Couldn't connect to proxy: #{e}"
        end
      end
      test << if response.code_type == Net::HTTPOK
                [id, response.body, now_time_int]
              else
                [id, "取得失敗", now_time_int]
              end

    end
  end

  def trade_seed_save(coincheck_client, path, id)
    CSV.open("#{path}/trade.csv",'a') do |test|
      test << %w(id json_body trade_time_int)
      begin
        retries = 0
        response = coincheck_client.read_trades
        now_time_int = Time.now.strftime("%Y%m%d%H%M%S").to_i
      rescue => e
        retries += 1
        if retries < 3
          retry # <-- Jumps to begin
        else
          # Error handling code, e.g.
          puts "Couldn't connect to proxy: #{e}"
        end
      end
      test << if response.code_type == Net::HTTPOK
                [id, response.body, now_time_int]
              else
                [id, "取得失敗", now_time_int]
              end

    end
  end

  def order_book_seed_save(coincheck_client, path, id)
    CSV.open("#{path}/order_book.csv",'a') do |test|
      test << %w(id json_body trade_time_int)
      begin
        retries = 0
        response = coincheck_client.read_order_books
        now_time_int = Time.now.strftime("%Y%m%d%H%M%S").to_i
      rescue => e
        retries += 1
        if retries < 3
          retry # <-- Jumps to begin
        else
          # Error handling code, e.g.
          puts "Couldn't connect to proxy: #{e}"
        end
      end
      test << if response.code_type == Net::HTTPOK
                [id, response.body, now_time_int]
              else
                [id, "取得失敗", now_time_int]
              end

    end
  end

  def rate_seed_save(btc_jpy_https, path, id)
    CSV.open("#{path}/rate.csv",'a') do |test|
      test << %w(id json_body trade_time_int pair)
      begin
        retries = 0
        uri = URI.parse("https://coincheck.jp/api/rate/btc_jpy")
        # public APIだから空で良い
        headers = {
            "ACCESS-KEY" => "",
            "ACCESS-NONCE" => "",
            "ACCESS-SIGNATURE" => ""
        }
        response = btc_jpy_https.start {
          btc_jpy_https.get(uri.request_uri, headers)
        }

        now_time_int = Time.now.strftime("%Y%m%d%H%M%S").to_i
      rescue => e
        retries += 1
        if retries < 3
          retry # <-- Jumps to begin
        else
          # Error handling code, e.g.
          puts "Couldn't connect to proxy: #{e}"
        end
      end
      test << if response.code_type == Net::HTTPOK
                [id, response.body, now_time_int, "btc_jpy"]
              else
                [id, "取得失敗", now_time_int, "btc_jpy"]
              end

    end
  end

end