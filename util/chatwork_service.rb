require 'chatwork'

class ChatworkService
  def initialize(api_key, room_id)
    ChatWork.api_key = api_key
    @room_id = room_id
    
  end

  def send_message(message:, room_id: @room_id)
    ChatWork::Message.create(room_id: room_id, body: message)
  end
end
