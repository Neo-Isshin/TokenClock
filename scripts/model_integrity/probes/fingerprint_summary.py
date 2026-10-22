"""Plain-language local comparisons, without a global model verdict."""
from collections import defaultdict

DIMENSIONS={'behavior':'行为偏好','capability_delivery':'逐项得失分','process':'工作过程','resources':'资源投入'}


def summarize(fingerprint):
    statements=[];directions=defaultdict(list)
    for panel in fingerprint.get('comparison_panels',[]):
        models=panel.get('per_model',[])
        if isinstance(models,dict):models=[{'model_label':k,**v} for k,v in models.items()]
        base={'panel_id':panel['id'],'subject_id':panel.get('subject_id'), 'subject_label':panel.get('subject_label','输入组'),
              'dimension':panel.get('dimension'),'task_family':panel.get('task_family'),'mode':panel.get('mode'),
              'feature_count':len(panel.get('feature_ids',[])), 'identity_verdict':False,'statistical_significance_tested':False}
        label=DIMENSIONS.get(panel.get('dimension'),panel.get('dimension','观察'))+' · '+str(panel.get('task_family'))
        if len(models)<2:
            statements.append({**base,'state':'one_reference_only','text':label+'目前只有一个可比参考，不能据此作型号间比较。'});continue
        if any(type(m.get('distance')) not in (int,float) for m in models):
            statements.append({**base,'state':'missing_measurements','text':label+'有缺测，保留距离范围，不给出单一接近方向。'});continue
        values={m['model_label']:m['distance'] for m in models};best=min(values.values());worst=max(values.values())
        nearest=sorted(k for k,v in values.items() if abs(v-best)<1e-12)
        if abs(worst-best)<1e-12:
            state='equal_observed_distance';text=label+'在当前共同特征上的距离相同，没有形成区分方向。'
        else:
            state='local_descriptive_direction';text=label+'的当前观察在数值上更接近 '+ ' / '.join(nearest)+' 的已有参考。'
            from .direction_guard import evaluate
            guard=evaluate(panel)
            base['direction_guard']=guard
            if guard['status']=='repeat_supported':directions[(panel.get('subject_id'),tuple(sorted(values)))].append((panel.get('task_family'),set(nearest)))
            else:text+=' '+guard['reasons'][0]
        if panel.get('mode')!='strict':text+=' 生成条件或测量来源不完全一致，此项仅作情境参考。'
        statements.append({**base,'state':state,'nearest_labels':nearest,'distances':values,'text':text})
    alignment=[]
    for (subject,cohort),rows in directions.items():
        if len({family for family,_ in rows})<2:continue
        common=set.intersection(*(near for _,near in rows))
        alignment.append({'subject_id':subject,'candidate_panel':list(cohort),'task_families':sorted({f for f,_ in rows}),
                          'state':'local_directions_share_candidates' if common else 'local_directions_differ',
                          'shared_nearest_labels':sorted(common),
                          'meaning':'同一候选集合上的局部方向摘要；未对相关证据重复投票，方向不同也不等于型号混用。'})
    return {'schema':'tokenclock-fingerprint-interpretation/v1','statements':statements,'alignment':alignment,
            'global_model_verdict':None,'identity_probability':None,
            'limitations':['这些文字只解释已观察到的分布距离，不代表稳定胜率或经验证的型号身份。',
                           '来源声明差异和直接路由记录仍需单独查看，接近某参考不会抵消它们。']}
