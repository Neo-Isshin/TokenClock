"""Explicit public catalog reads for the selected known service; never inference."""
from datetime import datetime,timezone
from decimal import Decimal,InvalidOperation
import json
from urllib.parse import urlsplit
from urllib.request import Request,build_opener
from ..probes.transport import NoRedirect

SERVICES={'openrouter.ai':('openrouter','https://openrouter.ai/api/v1/models','/api/v1/'),
          'opencode.ai':('zen','https://opencode.ai/zen/v1/models','/zen/v1/')}


def _price(value):
    try:
        n=Decimal(str(value))
        if not n.is_finite() or n<0 or n>Decimal('1'):return None
        return n
    except (InvalidOperation,ValueError):return None


def normalize(payload,service):
    if not isinstance(payload,dict) or not isinstance(payload.get('data'),list):raise ValueError('服务未返回可读取的型号目录')
    models=[];seen=set()
    for row in payload['data'][:2000]:
        if not isinstance(row,dict) or not isinstance(row.get('id'),str) or not 1<=len(row['id'])<=200 or any(ord(c)<32 for c in row['id']):continue
        if row['id'] in seen:continue
        seen.add(row['id']);item={'id':row['id'],'pricing_available':False,'input_usd_per_million':None,'output_usd_per_million':None}
        prices=row.get('pricing')
        if service=='openrouter' and isinstance(prices,dict):
            tiers=[prices]+[x for x in prices.get('overrides',[]) if isinstance(x,dict)] if isinstance(prices.get('overrides',[]),list) else []
            inputs=[];outputs=[];valid=bool(tiers)
            for tier in tiers:
                token_fields={'prompt','completion','input_cache_write','input_cache_write_1h','input_cache_read'}
                # These task bodies never request the service's web-search tool.
                ignored={'overrides','min_prompt_tokens','web_search'}
                for key,value in tier.items():
                    if key not in token_fields|ignored and _price(value)!=Decimal(0):valid=False
                for key in ('prompt','input_cache_write','input_cache_write_1h','input_cache_read'):
                    if key in tier:
                        price=_price(tier[key]);valid=valid and price is not None
                        if price is not None:inputs.append(price)
                if 'completion' in tier:
                    price=_price(tier['completion']);valid=valid and price is not None
                    if price is not None:outputs.append(price)
            if valid and _price(prices.get('prompt')) is not None and _price(prices.get('completion')) is not None and inputs and outputs:
                item.update(pricing_available=True,input_usd_per_million=float(max(inputs)*1000000),output_usd_per_million=float(max(outputs)*1000000),
                    pricing_note='目录各已返回档位与缓存费率的较高值，用于保守预留；不是实际账单或价格保证。')
        if not item['pricing_available']:item['pricing_note']='此目录未提供完整可用的token计费报价，或包含当前预留器未覆盖的附加费；不能自动填为零价，请核对完整计费方式。'
        models.append(item)
    return sorted(models,key=lambda x:x['id'])


def fetch_catalog(endpoint,*,opener=None):
    if not isinstance(endpoint,str):raise ValueError('请先填写完整接口地址')
    u=urlsplit(endpoint)
    if u.scheme!='https' or u.username or u.password or u.query or u.fragment or u.port not in (None,443):raise ValueError('请使用不含密钥和查询参数的HTTPS接口地址')
    selected=SERVICES.get(u.hostname)
    if selected is None or not u.path.startswith(selected[2]):raise ValueError('此自定义接口暂不支持自动读取目录，请手动填写型号与报价')
    service,url,_=selected
    request=Request(url,headers={'Accept':'application/json','User-Agent':'TokenClock-ModelDetect/1'})
    try:
        with (opener or build_opener(NoRedirect())).open(request,timeout=15) as response:
            data=response.read(4*1024*1024+1)
            if len(data)>4*1024*1024:raise ValueError('型号目录超过读取上限')
            payload=json.loads(data)
    except ValueError:raise
    except Exception as exc:raise ValueError('暂时无法读取该服务目录，请稍后手动重试或直接填写型号与报价') from None
    return {'service':service,'models':normalize(payload,service),'source_url':url,
            'observed_at':datetime.now(timezone.utc).isoformat(),'credential_sent':False,'model_requests':0}
