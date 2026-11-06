"""Offline Ailyre-to-TokenClock conversion and billing safeguards."""
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('pricing', Path(__file__).with_name('update-pricing-snapshot.py'))
pricing = importlib.util.module_from_spec(spec); spec.loader.exec_module(pricing)


def row(provider='openai', model='gpt-6.1-sol', **values):
    return dict(provider=provider, model=model, native_id=model, category='api', original=True,
                currency='USD', unit='USD / 1M tokens', tier='standard', input=2., output=10.,
                cache_read=.1, cache_write=None, **values)


def feed():
    rows = [row(model=f'gpt-fixture-{i}') for i in range(50)]
    rows += [row('anthropic', 'claude-sonnet-5-5'), row('google', 'gemini-4-argon')]
    return {'schema':4, 'unit':'USD / 1M tokens', 'generated_at':'2026-11-04T06:00:00Z', 'rows':rows}


class SnapshotTests(unittest.TestCase):
    def test_existing_prices_and_cache_rates_update_and_history_is_retained(self):
        data=feed();current={'models':pricing.validated_models(data,{})}
        current['models']['retired']={'in':1.,'out':3.}
        data['rows'][0].update(input=3.,output=12.,cache_read=.2)
        changed=pricing.validated_models(data,current)
        self.assertEqual((changed['gpt-fixture-0']['in'],changed['gpt-fixture-0']['out'],changed['gpt-fixture-0']['cr']),(3,12,.2))
        self.assertEqual(changed['retired'],current['models']['retired'])

    def test_standard_is_not_overwritten_by_batch_fast_ultrafast_cny_or_resellers(self):
        data=feed();base=row();data['rows']+=[base]
        for tier,value in [('batch',.5),('fast',4),('flex',.5)]:
            item=dict(base,tier=tier,input=value,output=value*5,cache_read=value/20)
            if tier=='fast':item['variant']='fast'
            data['rows'].append(item)
        data['rows'] += [dict(base,tier='fast',variant='ultrafast',input=12,output=60,cache_read=.6),
                         dict(base,currency='CNY',input=14),dict(base,provider='openrouter',input=.1)]
        price=pricing.validated_models(data,{})['gpt-6.1-sol']
        self.assertEqual((price['in'],price['out'],price['cr'],price['pm']),(2,10,.1,2))

    def test_long_context_threshold_and_uniform_priority_are_preserved(self):
        data=feed();base=row();data['rows'] += [base,dict(base,tier='long',variant='> 272k input tokens',input=4.,output=15.,cache_read=.2)]
        p=pricing.validated_models(data,{})['gpt-6.1-sol']
        self.assertEqual((p['lt'],p['lin'],p['lout'],p['lcr']),(272000,4,15,.2))

    def test_missing_fields_do_not_turn_unknown_cache_or_tiers_into_free(self):
        data=feed();data['rows'][0]['cache_read']=None
        old={'models':{'gpt-fixture-0':{'in':1.,'out':5.,'cr':.25,'cw':1.,'lt':272000,'lin':2.,'lout':8.,'pm':2.}}}
        price=pricing.validated_models(data,old)['gpt-fixture-0']
        self.assertEqual((price['in'],price['cr'],price['cw'],price['lt'],price['pm']),(2,.25,1,272000,2))

    def test_ambiguous_variants_do_not_choose_cheapest_or_delete_previous_rate(self):
        data=feed();base=row();data['rows'] += [base,dict(base,input=1.)]
        old={'models':{'gpt-6.1-sol':{'in':3.,'out':15.}}}
        self.assertEqual(pricing.validated_models(data,old)['gpt-6.1-sol'],old['models']['gpt-6.1-sol'])

    def test_partial_wrong_units_and_invalid_numeric_prices_are_rejected(self):
        for data in [{},dict(feed(),unit='CNY / 1M tokens'),dict(feed(),rows=[]),dict(feed(),rows=feed()['rows'][:3])]:
            with self.assertRaises(ValueError):pricing.validated_models(data,{})
        for bad in [-1,True,float('inf'),float('nan'),10001]:
            data=feed();data['rows'][0]['input']=bad
            with self.subTest(value=bad),self.assertRaises(ValueError):pricing.validated_models(data,{})

    def test_only_changed_prices_or_source_need_publication(self):
        models=pricing.validated_models(feed(),{});current=json.loads(pricing.render_snapshot(models))
        current['_meta']['generatedAt']='2000-01-01T00:00:00Z'
        self.assertFalse(pricing.snapshot_changed(current,models))
        self.assertTrue(pricing.snapshot_changed({'models':models},models))
        models['gpt-fixture-0']['in']=3
        self.assertTrue(pricing.snapshot_changed(current,models))

    def test_native_ids_and_stable_human_names_are_available_without_numeric_collisions(self):
        data=feed();data['rows'] += [row('deepseek','deepseek-flash') | {'model':'DeepSeek-V4.1-Flash-1017'},
            row('anthropic','claude-opus-5-5') | {'model':'Claude Opus 5.5'},
            row('qwen','qwen3.8-max') | {'model':'Qwen3.8 Max'}]
        models=pricing.validated_models(data,{})
        for key in ['deepseek-flash','deepseek-v4.1-flash','claude-opus-5-5','dashscope/qwen3.8-max']:
            self.assertIn(key,models)


if __name__=='__main__':unittest.main()
