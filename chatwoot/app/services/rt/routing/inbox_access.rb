# Agente humano do Chatwoot so enxerga caixas de que e membro. Quando uma conversa chega a uma fila
# (entrada ou repasse), os membros da fila passam a ser membros da caixa: sem isso o atendente da fila
# humana recebia 401 ao assumir a conversa repassada pela IA.
class Rt::Routing::InboxAccess
  def self.grant(team_id:, inbox:)
    return if team_id.blank? || inbox.nil?

    team = Team.find_by(id: team_id, account_id: inbox.account_id)
    return unless team

    team.team_members.includes(:user).find_each do |member|
      next if inbox.inbox_members.exists?(user_id: member.user_id)

      inbox.inbox_members.create!(user_id: member.user_id)
    end
  rescue StandardError => e
    Rails.logger.warn("rt inbox_access: #{e.class} #{e.message}")
  end
end
