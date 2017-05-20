module HttpModule
  def http_request(uri, request)
    https = Net::HTTP.new(uri.host, uri.port)
    if SSL
      https.use_ssl = true
      https.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end

    response = https.start do |h|
      h.request(request)
    end
  end

  def request_for_get(uri, headers = {}, body = nil)
    request = Net::HTTP::Get.new(uri.request_uri, initheader = headers)
    request.body = body.to_json if body
    http_request(uri, request)
  end

  def request_for_put(uri, headers = {}, body = nil)
    request = Net::HTTP::Put.new(uri.request_uri, initheader = headers)
    request.body = body.to_json if body
    http_request(uri, request)
  end
end