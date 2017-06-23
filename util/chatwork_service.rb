require 'chatwork'

class ChatworkService
  def initialize(api_key, room_id, is_action)
    ChatWork.api_key = api_key
    @room_id = room_id
    @is_action = is_action

    # API通信の仕様で5分に100回となっているので、3秒に一回のみ処理を行うようにする
    @connected_time = Time.now.to_i
  end

  def send_message(message:, room_id: @room_id)
    return nil unless @is_action
    return nil unless time_check

    ChatWork::Message.create(room_id: room_id, body: message)
  end

  def get_message(room_id: @room_id)
    return [] unless @is_action
    return [] unless time_check

    begin
      result = ChatWork::Message.get(room_id: room_id)
    rescue => e
      # そこまで緊急ではないと思うので失敗時はスキップ
      return []
    end

    if result.class == Array
      result.map { |msg| msg["body"] }
    else
      []
    end
  end

  # API通信の仕様で5分に100回となっているので、3秒に一回のみ処理を行うようにする
  def time_check
    if @connected_time + 3 < Time.now.to_i
      @connected_time = Time.now.to_i
      return true
    else
      return false
    end
  end
end
