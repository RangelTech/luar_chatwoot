import { mount } from '@vue/test-utils';
import ProviderCostPanel from './ProviderCostPanel.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, te: () => true }),
}));

// Regressao 25/10/2026: a tabela "por hora" recebia o ref em vez do valor e a tela Consumo quebrava
// ("Cannot read properties of undefined (reading 'hour')") quando havia requisicoes.
const DATA = {
  requests: 12,
  promptTokens: 1000,
  completionTokens: 200,
  errors: 0,
  cost: 0.01,
  byProvider: [{ provider: 'codex', requests: 12, promptTokens: 1000, completionTokens: 200 }],
  byModel: [{ provider: 'codex', model: 'gpt', requests: 12, promptTokens: 1000, completionTokens: 200 }],
  byCombo: [],
  byHour: [
    { hour: '2026-10-25T09:00', requests: 5, promptTokens: 400, completionTokens: 50 },
    { hour: '2026-10-25T10:00', requests: 7, promptTokens: 600, completionTokens: 150 },
  ],
  byDay: [{ day: '2026-10-25', requests: 12, promptTokens: 1000, completionTokens: 200 }],
};

describe('ProviderCostPanel', () => {
  it('monta com dados por hora sem erro e mostra as horas', () => {
    const wrapper = mount(ProviderCostPanel, { props: { data: DATA } });
    expect(wrapper.text()).toContain('10-25 09:00');
    expect(wrapper.text()).toContain('10-25 10:00');
  });

  it('mostra o estado vazio sem requisicoes', () => {
    const wrapper = mount(ProviderCostPanel, { props: { data: { ...DATA, requests: 0, byHour: [] } } });
    expect(wrapper.find('[data-testid="provider-cost-panel"]').exists()).toBe(true);
  });
});
