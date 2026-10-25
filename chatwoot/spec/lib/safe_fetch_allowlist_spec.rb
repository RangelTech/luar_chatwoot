require 'rails_helper'

# Fork LUAR: o webhook do Agent Bot vai ao bridge na rede interna; so os hosts da lista passam pelo bloqueio de IP privado.
RSpec.describe SafeFetch do
  around do |example|
    keys = %w[SAFE_FETCH_ALLOW_PRIVATE_NETWORK SAFE_FETCH_PRIVATE_HOST_ALLOWLIST]
    saved = keys.index_with { |k| ENV.fetch(k, nil) }
    keys.each { |k| ENV.delete(k) }
    example.run
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  it 'bloqueia host privado por padrao' do
    expect(described_class.allow_private_network?('chatwoot-bridge')).to be(false)
  end

  it 'libera so o host da lista (sem diferenciar maiusculas)' do
    ENV['SAFE_FETCH_PRIVATE_HOST_ALLOWLIST'] = 'chatwoot-bridge, outro-interno'
    expect(described_class.allow_private_network?('Chatwoot-Bridge')).to be(true)
    expect(described_class.allow_private_network?('postgres')).to be(false)
    expect(described_class.allow_private_network?(nil)).to be(false)
  end

  it 'mantem o interruptor global antigo' do
    ENV['SAFE_FETCH_ALLOW_PRIVATE_NETWORK'] = 'true'
    expect(described_class.allow_private_network?('qualquer')).to be(true)
  end
end
