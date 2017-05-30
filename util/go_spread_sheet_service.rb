require 'oauth2'

class GoSpreadSheetService
  attr_accessor :ws_info

  def initialize(client_id, client_secret, refresh_token, spread_sheet_key)
    client = OAuth2::Client.new(
        client_id,
        client_secret,
        site: "https://accounts.google.com",
        token_url: "/o/oauth2/token",
        authorize_url: "/o/oauth2/auth")
    auth_token = OAuth2::AccessToken.from_hash(client,{:refresh_token => refresh_token, :expires_at => 3600})
    auth_token = auth_token.refresh!
    session = GoogleDrive.login_with_oauth(auth_token.token)

    @worksheets = session.spreadsheet_by_key(spread_sheet_key).worksheets

    # google spread sheet制御変数
    @ws_info = {
        bollinger_band_ws: {
            row_index: 2,
            data_time: nil
        }
    }
  end

  # 横一列に値を設定する
  def set_line(lines:, x_position:, y_position:, sheet_index:)
    header_size = lines.size
    @worksheets[sheet_index]
    header_size.times do |index|
      @worksheets[sheet_index][y_position, x_position + index] = lines[index]
    end
    @worksheets[sheet_index].save
  end

  def get_value(x_position:, y_position:, sheet_index:)
    @worksheets[sheet_index][x_position, y_position]
  end

  # go_spreadsheet_service.set_line(lines: %w(aaa sss ddd fff ggg hhh jjj),
  #                                 x_position: 1,
  #                                 y_position: 1,
  #                                 sheet_index: 0)
end