"""Conservative admission of repeated local directions, not a calibrated identity test.

These are explicit engineering safeguards. They do not supply p-values, population
accuracy or backend identity odds. All rejected directions remain descriptive data.
"""
from __future__ import annotations
import math

SCHEMA='tokenclock-local-direction-guard/v1'
MIN_SAMPLES=2
MIN_MARGIN=0.10
MAX_NEAREST_DISTANCE=0.35


def _counts(value):
    return isinstance(value,dict) and bool(value) and all(isinstance(k,str) and type(v)is int and v>0 for k,v in value.items())

def _tv(a,b):
    n,m=sum(a.values()),sum(b.values())
    return sum(abs(a.get(k,0)/n-b.get(k,0)/m) for k in set(a)|set(b))/2


def evaluate(panel):
    result={'schema':SCHEMA,'status':'descriptive_only','reasons':[],
            'minimum_samples':MIN_SAMPLES,'minimum_margin':MIN_MARGIN,'maximum_nearest_distance':MAX_NEAREST_DISTANCE,
            'calibration':'engineering_safeguards_not_validated_identity_error_rate',
            'statistical_significance_tested':False,'identity_probability':None}
    def stop(reason):
        result['reasons'].append(reason);return result
    if panel.get('dimension')=='resources':return stop('资源记录只作辅助观察，不单独产生型号方向。')
    if panel.get('mode')!='strict':return stop('生成条件或测量来源不一致，只保留情境参考。')
    models=panel.get('per_model');features=panel.get('feature_ids')
    if not isinstance(models,list) or len(models)<2 or not isinstance(features,list) or not features:return stop('缺少共同可比项目。')
    labels=[m.get('model_label') for m in models if isinstance(m,dict)]
    if len(labels)!=len(models) or any(not isinstance(x,str) or not x for x in labels) or len(set(labels))!=len(labels):return stop('候选型号标签不完整或重复。')
    scores={};half_scores=[{},{}];self_distances=[];common={}
    minimum_current=math.inf;minimum_reference=math.inf
    for model in models:
        rows=model.get('features')
        if not isinstance(rows,list):return stop('旧记录缺少可复核的逐项分布。')
        by_id={row.get('feature_id'):row for row in rows if isinstance(row,dict)}
        values=[];halves=[[],[]]
        for name in features:
            row=by_id.get(name,{})
            a,b=row.get('current_counts'),row.get('reference_counts');split=row.get('current_split_counts')
            ids=row.get('current_sample_ids')
            if not _counts(a) or not _counts(b):return stop('缺少有效的回答计数。')
            if not isinstance(ids,list) or any(not isinstance(i,str) for i in ids) or len(set(ids))!=sum(a.values()):return stop('重复回答缺少独立样本标识，不能确认重复次数。')
            if row.get('current_coverage')!=1 or row.get('reference_coverage')!=1:return stop('当前或参考样本存在缺测。')
            if row.get('condition_notes'):return stop('比较条件存在差异，只保留情境参考。')
            minimum_current=min(minimum_current,sum(a.values()));minimum_reference=min(minimum_reference,sum(b.values()))
            if min(sum(a.values()),sum(b.values()))<MIN_SAMPLES:return stop('当前或参考的独立样本少于两份。')
            if not isinstance(split,list) or len(split)!=2 or not all(_counts(s) for s in split):return stop('缺少按实际重复顺序分开的两组回答。')
            if {k:split[0].get(k,0)+split[1].get(k,0) for k in set(split[0])|set(split[1])}!=a:return stop('重复分组与总计数不一致。')
            signature=(a,split,ids)
            if name in common and common[name]!=signature:return stop('不同参考使用的当前样本集合不一致。')
            common[name]=signature
            values.append(_tv(a,b))
            for index in range(2):halves[index].append(_tv(split[index],b))
            if len(scores)==0:self_distances.append(_tv(split[0],split[1]))
        score=sum(values)/len(values)
        original=model.get('distance')
        if type(original) not in (int,float) or not math.isfinite(original) or abs(score-original)>1e-9:return stop('分布计数与报告距离不一致。')
        scores[model['model_label']]=score
        for index in range(2):half_scores[index][model['model_label']]=sum(halves[index])/len(halves[index])
    ordered=sorted(scores,key=lambda name:(scores[name],name));best=ordered[0]
    margin=scores[ordered[1]]-scores[best]
    self_distance=sum(self_distances)/len(self_distances)
    result.update(nearest=best,margin=margin,nearest_distance=scores[best],self_distance=self_distance,
                  current_min_n=int(minimum_current),reference_min_n=int(minimum_reference))
    if margin<MIN_MARGIN-1e-12:return stop('与第二候选的差距小于保护门槛，暂不提升为偏离结论。')
    if scores[best]>MAX_NEAREST_DISTANCE+1e-12:return stop('与最近参考的绝对差异仍然较大，可能不属于当前候选。')
    if self_distance>=margin-1e-12:return stop('两组重复回答的波动不小于候选差距。')
    for values in half_scores:
        ranking=sorted(values,key=lambda name:(values[name],name))
        if ranking[0]!=best or values[ranking[1]]-values[best]<MIN_MARGIN-1e-12:
            return stop('分开查看两组重复回答时，接近方向不稳定或差距不足。')
    result.update(status='repeat_supported',reasons=['两组重复观察方向一致，并通过差距、缺测和条件检查；仍是局部弱信号。'])
    return result
