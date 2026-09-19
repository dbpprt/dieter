import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizeUsage } from './quota-claude.mjs';

test('normalizes Claude session, weekly, model, and spend windows', () => {
  const result = normalizeUsage(
    {
      orgId: 'org_test',
      email: 'Person@Example.com',
      subscriptionType: 'max',
    },
    {
      five_hour: { utilization: 12.2, resets_at: '2026-09-19T20:00:00Z' },
      seven_day: { utilization: 48, resets_at: '2026-09-25T20:00:00Z' },
      seven_day_opus: { utilization: 7.1, resets_at: '2026-09-25T20:00:00Z' },
      spend: {
        enabled: true,
        used: { amount_minor: 1840, exponent: 2, currency: 'usd' },
        limit: { amount_minor: 10000, exponent: 2, currency: 'usd' },
        percent: 18.4,
      },
    },
  );

  assert.equal(result.stableAccountID, 'org_test\u0000person@example.com');
  assert.equal(result.displayEmail, 'Person@Example.com');
  assert.equal(result.plan, 'max');
  assert.deepEqual(result.windows, [
    {
      id: 'five_hour', label: '5h', kind: 'five_hour', usedPercent: 13,
      remainingPercent: 87, durationMinutes: 300, resetsAt: '2026-09-19T20:00:00Z',
    },
    {
      id: 'seven_day', label: 'Week', kind: 'weekly', usedPercent: 48,
      remainingPercent: 52, durationMinutes: 10_080, resetsAt: '2026-09-25T20:00:00Z',
    },
    {
      id: 'seven_day_opus', label: 'Opus week', kind: 'model', usedPercent: 8,
      remainingPercent: 92, durationMinutes: 10_080, resetsAt: '2026-09-25T20:00:00Z',
    },
  ]);
  assert.deepEqual(result.spendAllowance, {
    used: '18.40 USD',
    limit: '100.00 USD',
    currency: 'USD',
    remainingPercent: 82,
  });
  assert.equal(result.ordinaryUsageAllowed, true);
});

test('clamps utilization and omits unavailable optional data', () => {
  const result = normalizeUsage(
    { orgId: 'org_test', email: 'person@example.com' },
    {
      five_hour: { utilization: 112 },
      seven_day: { utilization: Number.NaN },
    },
  );

  assert.deepEqual(result.windows, [{
    id: 'five_hour', label: '5h', kind: 'five_hour', usedPercent: 100,
    remainingPercent: 0, durationMinutes: 300, resetsAt: undefined,
  }]);
  assert.equal(result.spendAllowance, undefined);
  assert.equal(result.ordinaryUsageAllowed, false);
});
