require 'chatwork'

class ChatworkService
  def initialize(api_key, room_id, is_action)
    ChatWork.api_key = api_key
    @room_id = room_id
    @is_action = is_action
    
  end

  def send_message(message:, room_id: @room_id)
    return nil unless @is_action

    ChatWork::Message.create(room_id: room_id, body: message)
  end

  def get_message(room_id: @room_id)
    return [] unless @is_action

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
end
