"""Explicit controller-side connection reuse; never inferred from target content."""
from copy import deepcopy


def resolve_shared_review(config, *, include_secret=True):
    result=deepcopy(config)
    review=result.get('assessment') or {}
    if not isinstance(review,dict):raise ValueError('评审配置无效')
    source=review.get('connection_source','separate')
    if source not in {'separate','target'}:raise ValueError('评审连接来源无效')
    if not review.get('enabled') or source=='separate':return result
    if result.get('workflow_mode') not in {'l2','l3'} or result.get('transport_mode')!='live':
        raise ValueError('只有本次真实探针调用可以复用待测连接；已有文件或回放请明确选择解析连接')
    target=result.get('provider') or {};provider=review.get('provider') or {}
    if not isinstance(target,dict) or not isinstance(provider,dict):raise ValueError('待测或解析连接配置无效')
    for key in ('endpoint','api_format'):
        expected=target.get(key,'responses' if key=='api_format' else None)
        if provider.get(key) is not None and provider[key]!=expected:raise ValueError('复用待测连接时不能另指定不同接口或协议')
        provider[key]=expected
    provider.pop('connection_id',None)
    provider['model']=provider.get('model') or target.get('model')
    if provider['model']==target.get('model'):
        for key in ('input_usd_per_million','output_usd_per_million','cache_read_usd_per_million','cache_write_usd_per_million'):
            if provider.get(key) is None and key in target:provider[key]=target[key]
    provider.pop('api_key',None)
    if include_secret and target.get('api_key'):provider['api_key']=target['api_key']
    review['provider']=provider;result['assessment']=review
    return result
