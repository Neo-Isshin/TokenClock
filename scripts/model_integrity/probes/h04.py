"""Safe SVG / original-character ASCII rendering and conditional geometry.

Object roles come only from SHA-bound prior review or a configured proposal
interface. Candidate ids/comments and XML validity never establish semantics.
"""
import hashlib
import html
import json
import math
from pathlib import Path
import re
import time
import unicodedata
import xml.etree.ElementTree as ET
from importlib import resources

from .browser_driver import check, run_driver, save, source_metadata
from . import visual_assessment

RESOURCE = resources.files(__package__).joinpath('resources/h04_annotations.json')
SVG_TAGS = {'svg','g','path','circle','ellipse','rect','line','polyline','polygon','defs','linearGradient',
            'radialGradient','stop','clipPath','mask','use','title','desc','text','tspan','filter','feDropShadow'}


def svg_source(text):
    matches = re.findall(r'<svg\b[\s\S]*?</svg\s*>', text, re.I)
    if len(matches) != 1:
        raise ValueError('Expected one unambiguous SVG')
    body = matches[0]
    if '<!DOCTYPE' in text.upper() or '<!ENTITY' in text.upper():
        raise ValueError('External/XML entity declarations are disallowed')
    root = ET.fromstring(body)
    elements = list(root.iter())
    if len(elements) > 800:
        raise ValueError('SVG element limit exceeded')
    filters = [e for e in elements if e.tag.rsplit('}', 1)[-1] == 'filter']
    shadows = [e for e in elements if e.tag.rsplit('}', 1)[-1] == 'feDropShadow']
    if len(filters) > 8 or len(shadows) > 8:
        raise ValueError('Static shadow filter count exceeds bounded limit')
    for f in filters:
        if set(f.attrib) - {'id','x','y','width','height','filterUnits','color-interpolation-filters'}:
            raise ValueError('Unsupported static filter attribute')
        if not 1 <= len(f) <= 2 or any(c.tag.rsplit('}', 1)[-1] != 'feDropShadow' for c in f):
            raise ValueError('Only bounded static drop-shadow filters are supported')
        if f.get('filterUnits', 'objectBoundingBox') != 'objectBoundingBox':
            raise ValueError('Unbounded filter coordinate units')
        for name, default in [('x','-10%'), ('y','-10%'), ('width','120%'), ('height','120%')]:
            raw = f.get(name, default)
            try: number = float(raw[:-1]) / 100 if raw.endswith('%') else float(raw)
            except ValueError: raise ValueError('Invalid static filter extent') from None
            if not math.isfinite(number) or not (-1 <= number <= 1 if name in ('x','y') else 0 < number <= 3):
                raise ValueError('Static filter extent exceeds bounded limit')
    for s in shadows:
        if len(s) or set(s.attrib) - {'dx','dy','stdDeviation','flood-color','flood-opacity','color-interpolation-filters'}:
            raise ValueError('Unsupported static drop-shadow attribute or child')
        if not any(s in list(f) for f in filters): raise ValueError('Drop shadow must belong to a static filter')
        for name, default in [('dx','2'), ('dy','2'), ('stdDeviation','2')]:
            try: values = [float(x) for x in re.split(r'[\s,]+', s.get(name, default).strip())]
            except ValueError: raise ValueError('Invalid drop-shadow numeric parameter') from None
            if not 1 <= len(values) <= (2 if name == 'stdDeviation' else 1) or any(not math.isfinite(x) or abs(x) > 64 or (name == 'stdDeviation' and x < 0) for x in values):
                raise ValueError('Static drop-shadow parameter exceeds bounded limit')
    for element in elements:
        if element.tag.rsplit('}', 1)[-1] not in SVG_TAGS:
            raise ValueError('Active or unsupported SVG element')
        for raw_name, value in element.attrib.items():
            name = raw_name.rsplit('}', 1)[-1].casefold()
            if name.startswith('on') or (name in {'href','src'} and not value.startswith('#')):
                raise ValueError('External or executable SVG attribute')
            if re.search(r'@import|javascript:|data:|https?:|file:|\\', value, re.I):
                raise ValueError('External/encoded SVG resource')
            if any(not token.startswith('#') for token in re.findall(r'url\(\s*[\'\"]?([^\)\'\"\s]+)', value, re.I)):
                raise ValueError('External SVG resource')
    return body, elements


def ascii_frames(text):
    blocks = re.findall(r'^```[^\n]*\n([\s\S]*?)^```\s*$', text, re.M)
    if len(blocks) != 8:
        raise ValueError('Eight explicit original code blocks required; ambiguous framing is unknown')
    frames = [block.removesuffix('\n').split('\n') for block in blocks]
    if any(len(frame) > 100 or any(len(line) > 200 for line in frame) for frame in frames):
        raise ValueError('ASCII display dimensions exceed bounded limit')
    return frames


def width(line):
    n = 0
    for char in line:
        if char == '\t': n = (n // 8 + 1) * 8
        elif unicodedata.combining(char): continue
        else: n += 2 if unicodedata.east_asian_width(char) in 'WF' else 1
    return n


def frames_svg(frames):
    cols = max(width(line) for frame in frames for line in frame)
    rows = max(len(frame) for frame in frames)
    panel_w, panel_h = cols * 11 + 28, rows * 18 + 44
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{panel_w*2}" height="{panel_h*4}">', '<rect width="100%" height="100%" fill="white"/>']
    for i, frame in enumerate(frames):
        x, y = i % 2 * panel_w + 14, i // 2 * panel_h
        out.append(f'<text x="{x}" y="{y+18}" font-size="13">Frame {i+1}</text>')
        for j, line in enumerate(frame):
            out.append(f'<text x="{x}" y="{y+38+j*18}" xml:space="preserve" font-family="monospace" font-size="17">{html.escape(line.expandtabs(8))}</text>')
    out.append('</svg>')
    return '\n'.join(out)


def validate_annotation(annotation, digest, kind, elements=None, frames=None):
    if not isinstance(annotation, dict) or annotation.get('source_sha256') != digest or annotation.get('kind') != kind:
        raise ValueError('Semantic proposal is not bound to the exact source hash/kind')
    allowed={'source_sha256','kind','origin','parent_sha256','roles'if kind=='svg'else'frames'}
    if set(annotation)-allowed:
        raise ValueError('Geometry proposal contains unsupported fields; scores/identity/verification claims are not accepted')
    if kind == 'svg':
        roles = annotation.get('roles', {})
        if set(roles) != {'hands','tie','mirror','reflection_head'} or not isinstance(roles['hands'], list) or not 1 <= len(roles['hands']) <= 4:
            raise ValueError('SVG role proposal must identify hands, tie, mirror and reflection head')
        selected = roles['hands'] + [roles[k] for k in ('tie','mirror','reflection_head')]
        for role in selected:
            if not isinstance(role, dict) or set(role) - {'element','instance'}:
                raise ValueError('Only structural element/instance indices are accepted')
            i = role.get('element')
            if type(i) is not int or not 0 <= i < len(elements):
                raise ValueError('Object element does not exist')
            if elements[i].tag.rsplit('}',1)[-1] not in {'path','circle','ellipse','rect','line','polyline','polygon'}:
                raise ValueError('Selected object has no supported geometry')
            if 'instance' in role:
                j = role['instance']
                if type(j) is not int or not 0 <= j < len(elements) or elements[j].tag.rsplit('}',1)[-1] != 'use':
                    raise ValueError('Invalid use-instance reference')
        identities = [(r['element'], r.get('instance')) for r in selected]
        if len(identities) != len(set(identities)):
            raise ValueError('Different semantic objects cannot share the same selected geometry instance')
    else:
        maps = annotation.get('frames')
        if not isinstance(maps, list) or len(maps) != len(frames):
            raise ValueError('One coordinate map is required per original frame')
        if any(any(ord(c)>127 or c=='\t' for c in line) for frame in frames for line in frame):
            raise ValueError('Semantic grid proposal needs plain ASCII cells; original text stays preserved')
        def point(p, frame):
            return isinstance(p,list) and len(p)==2 and all(type(x)is int for x in p) and 0<=p[1]<len(frame) and 0<=p[0]<len(frame[p[1]]) and frame[p[1]][p[0]] not in ' .\r'
        for mapping, frame in zip(maps, frames):
            if not isinstance(mapping,dict) or not point(mapping.get('head'),frame):
                raise ValueError('Head coordinate is absent/background')
            for name in ('feet','crate_corners','ground_cells','push_chain'):
                ps=mapping.get(name)
                if not isinstance(ps,list) or not ps or len(ps)>1000 or not all(point(p,frame) for p in ps):
                    raise ValueError('Missing or invalid semantic coordinates: '+name)
            if len(mapping['crate_corners']) != 4:
                raise ValueError('Four visible crate corners are required by this grid adapter')
    return annotation


def ascii_geometry(frames, annotation):
    observations = []
    for index, (frame, roles) in enumerate(zip(frames, annotation['frames'])):
        ground = {tuple(p) for p in roles['ground_cells']}
        feet = [{'point': foot, 'supported_below': (foot[0], foot[1]+1) in ground,
                 'first_ground_below': next((y for y in range(foot[1]+1,len(frame)) if (foot[0],y) in ground), None)} for foot in roles['feet']]
        corners = roles['crate_corners']
        crate_support = any((x+dx,y+dy) in ground for x,y in corners for dx,dy in ((0,1),(1,0),(-1,0)))
        chain = roles['push_chain']
        chain_connected = all(abs(a[0]-b[0])+abs(a[1]-b[1])==1 for a,b in zip(chain,chain[1:]))
        observations.append({'frame': index+1, 'head': roles['head'], 'feet': feet,
            'person_supported': any(f['supported_below'] for f in feet), 'crate_supported': crate_support,
            'push_chain_connected': chain_connected,
            'crate_center':[sum(p[0] for p in corners)/4,sum(p[1] for p in corners)/4],
            'crate_size':[max(p[0]for p in corners)-min(p[0]for p in corners),max(p[1]for p in corners)-min(p[1]for p in corners)],
            'head_character':frame[roles['head'][1]][roles['head'][0]]})
    heads=[r['head'] for r in observations]; boxes=[r['crate_center'] for r in observations]
    max_step=max(4,max(r['crate_size'][0] for r in observations)*2)
    uphill=lambda points: points[-1][0]!=points[0][0] and points[-1][1]<points[0][1] and all(abs(b[0]-a[0])+abs(b[1]-a[1])<=max_step for a,b in zip(points,points[1:]))
    same_direction=(heads[-1][0]-heads[0][0])*(boxes[-1][0]-boxes[0][0])>0
    return {'frames':observations,'uphill_continuity':uphill(heads)and uphill(boxes)and same_direction,
            'motion_rule':'Net uphill displacement to either side, shared direction, bounded inter-frame steps; not precise gait/physics.',
            'object_identity_consistent':len({r['head_character']for r in observations})==1 and len({tuple(r['crate_size'])for r in observations})==1}


def evaluate(source_path, output_dir, config=None, cancelled=None, progress=None):
    config=config or {};cancelled=cancelled or(lambda:False);start=time.monotonic()
    wall_budget=min(300,max(2,float(config.get('wall_seconds',120))))
    output=Path(output_dir)
    if output.is_symlink() or(output.exists()and any(output.iterdir())):raise ValueError('Refusing to replace existing evaluation evidence')
    if Path(source_path).stat().st_size>1024*1024:raise ValueError('Visual source exceeds 1 MiB')
    output.mkdir(parents=True,exist_ok=True,mode=0o700);output.chmod(0o700)
    raw=Path(source_path).read_bytes();digest=hashlib.sha256(raw).hexdigest()
    result={'schema':'tokenclock-task-result/v1','task_id':'H04','status':'limited','checks':[],
            'grader_version':'h04-visual-assessment/v2','model_assessed_checks':[],
            'model_assessment_status':'not_requested',
            'source':source_metadata(raw,config),'execution':{'actor':'evaluator','target_model_calls':0,'network_calls':0},
            'artifacts':[],'limitations':['Object roles are never inferred from candidate ids/comments.',
              'Prior SHA-bound annotations are previously reviewed fixtures, not new blind semantic evaluations.',
              'Configured semantic proposals can still misidentify objects; geometric results are conditional on selected roles.',
              'Model-assessed task judgments are separate from objective/conditional geometry; validated coordinates do not certify visual meaning.',
              'SVG fill/stroke samples and head bounding boxes do not fully model occlusion, perspective, clipping, or mirror optics.']}
    try:
        if len(raw)>1024*1024:raise ValueError('Visual source exceeds 1 MiB')
        text=raw.decode('utf-8');kind=config.get('variant') or ('svg' if '<svg' in text.lower() else 'ascii')
        if kind in ('OA11','H04-SVG'):kind='svg'
        if kind in ('OA12','H04-ASCII'):kind='ascii'
        result['variant']=kind
        if cancelled():result['status']='cancelled';return result
        elements=frames=None
        if kind=='svg':body,elements=svg_source(text)
        elif kind=='ascii':
            frames=ascii_frames(text);body=frames_svg(frames);save(output/'frames.json',{'frames':frames,'source_sha256':digest,'original_characters_preserved':True})
            result['checks'].append(check('h04.frame_structure','pass' if len({len(f)for f in frames})==1 else 'fail',
                {'frame_count':len(frames),'row_counts':[len(f)for f in frames],'max_display_widths':[max(map(width,f))for f in frames]},'H04-CANVAS'))
        else:raise ValueError('Unsupported H04 variant')
        artifact=output/'artifact.svg';artifact.write_text(body);artifact.chmod(0o600)
        result['checks'].append(check('h04.safe_structure','pass',{'kind':kind,'artifact_sha256':hashlib.sha256(body.encode()).hexdigest()},'H04-STRUCTURE',mandatory=False))
        known=json.loads(RESOURCE.read_text()) if RESOURCE.is_file() else {}
        annotation=known.get(digest);trusted=annotation is not None
        if config.get('annotation') is not None:annotation=config['annotation'];trusted=False
        # Render first so an optional semantic provider sees the actual artifact.
        driver_cfg=dict(config);driver_cfg.pop('annotation',None);driver_cfg['full_page']=True
        if progress:progress('h04_render','渲染原始图形并采集结构',.25)
        initial=run_driver('svg',artifact,output,driver_cfg,cancelled);save(output/'initial-render.json',initial)
        result['render_coverage']=dict(initial.get('render_coverage')or{'complete':False,'reason':'renderer_coverage_receipt_unavailable'})
        if initial.get('driver_status')!='completed':
            result['checks'].append(check('h04.execution_complete','unknown',{'status':initial.get('driver_status'),'stop_reason':initial.get('stop_reason')},'H04-ENVIRONMENT'))
        loopback_total=initial.get('loopback_requests',0)
        for p in initial.get('screenshots',[]):result['artifacts'].append({'path':p,'media_type':'image/png','purpose':'Original visual rendering'})
        rendered=bool(initial.get('screenshots'))
        result['checks'].append(check('h04.actual_render','pass' if rendered else 'unknown',{'driver_status':initial.get('driver_status')},'H04-RENDER'))
        if callable(config.get('semantic_proposer')) and config.get('semantic_proposer_authorized') is True and not cancelled():
            render_coverage=dict(initial.get('render_coverage')or{})
            if render_coverage.get('artifact_sha256')!=hashlib.sha256(artifact.read_bytes()).hexdigest():
                render_coverage['complete']=False
            request=visual_assessment.build_request(kind,digest,initial.get('screenshots',[]),
                initial.get('geometry',{}).get('inventory'),frames,max(0,wall_budget-(time.monotonic()-start)),view_coverage=render_coverage)
            save(output/'visual-assessment-input.json',request)
            try:
                envelope=config['semantic_proposer'](request)
                result['execution']['semantic_proposal_calls']=1
                if isinstance(envelope,dict) and envelope.get('schema')==visual_assessment.ENVELOPE_SCHEMA:
                    core,controller=visual_assessment.project_envelope(envelope)
                    assessment=visual_assessment.validate_envelope(core,request,
                        lambda proposal:validate_annotation(proposal,digest,kind,elements,frames))
                    assessment['controller']=controller
                    result['visual_assessment']=assessment
                    result['model_assessment_status']=assessment['status']
                    if not annotation and assessment.get('geometry_proposal'):
                        annotation=assessment['geometry_proposal'];trusted=False
                    result['execution']['assessment_review_slots']=assessment['requested_reviews']
                elif isinstance(envelope,dict) and envelope.get('source_sha256')==digest and envelope.get('kind')==kind:
                    # Compatibility: an old geometry-only adapter supplies no
                    # task judgment and is never promoted to certified semantics.
                    if not annotation:annotation=envelope;trusted=False
                    result['model_assessment_status']='legacy_geometry_only'
                else:
                    result['visual_assessment']=visual_assessment.validate_envelope(envelope,request)
                    result['model_assessment_status']='unknown'
            except Exception as exc:
                result['execution']['semantic_proposal_calls']=1
                result['visual_assessment']=visual_assessment.validate_envelope(None,request)
                result['visual_assessment']['errors']=['assessment_callback_unavailable:'+type(exc).__name__]
                result['model_assessment_status']='unknown'
            if 'visual_assessment'in result:
                assessment_path=output/'visual-assessment.json'
                result['visual_assessment']['geometry_selection']='prior_sha_bound_review'if trusted else'validated_proposed_locations'if annotation else'unavailable'
                save(assessment_path,result['visual_assessment'])
                result['model_assessed_checks']=visual_assessment.assessment_checks(result['visual_assessment'],assessment_path)
                result['artifacts'].append({'path':str(assessment_path),'media_type':'application/json','purpose':'Model-assessed criteria, source bindings, agreement and disagreement; not certified semantics'})
        if annotation:
            try:annotation=validate_annotation(annotation,digest,kind,elements,frames)
            except ValueError as exc:
                result['checks'].append(check('h04.proposal_binding','unknown',{'proposal_accepted':False},'H04-SEMANTICS',reason=str(exc)))
                annotation=None;trusted=False
        semantic_status='pass' if annotation and trusted else 'unknown'
        result['checks'].append(check('h04.semantic_objects',semantic_status,{'origin':'prior_sha_bound_review'if trusted else 'configured_proposal'if annotation else 'unavailable'},'H04-SEMANTICS',
            reason=None if trusted else 'Object identities are not independently established for this source.'))
        if annotation:
            save(output/'accepted-proposal.json',annotation)
            result['checks'].append(check('h04.proposal_binding','pass',{'source_sha256':digest,'indices_and_coordinates_validated':True},'H04-SEMANTICS',mandatory=False))
            if kind=='svg':
                if progress:progress('h04_geometry','核验对象提案与实际几何关系',.65)
                remaining=wall_budget-(time.monotonic()-start)
                measured=run_driver('svg',artifact,output,dict(config,annotation=annotation,wall_seconds=remaining),cancelled) if remaining>=2 and not cancelled() else {'driver_status':'limited','stop_reason':'overall_wall_or_cancel_limit'}
                if measured.get('driver_status')!='completed'and not any(c['id']=='h04.execution_complete'for c in result['checks']):
                    result['checks'].append(check('h04.execution_complete','unknown',{'status':measured.get('driver_status'),'stop_reason':measured.get('stop_reason')},'H04-ENVIRONMENT'))
                save(output/'geometry-browser-result.json',measured);loopback_total+=measured.get('loopback_requests',0)
                geo=measured.get('geometry',{});save(output/'geometry.json',geo)
                contacts=geo.get('contacts',[])
                result['checks'].append(check('h04.tie_contact','pass' if any(c.get('overlap_witness')for c in contacts) else 'fail'if contacts else 'unknown',contacts,'H04-ACTION'))
                inside=geo.get('reflection_head_inside_mirror')
                result['checks'].append(check('h04.reflection_in_mirror','pass'if inside is True else 'fail'if inside is False else 'unknown',
                    {'reflection_head_bounds':geo.get('reflection_head_bounds'),'mirror_bounds':geo.get('mirror_bounds'),
                     'reflection_head_inside_mirror':inside},'H04-MIRROR'))
                # Exact use-instance mapping verifies shared geometry; semantic viewpoint remains the prior review's scope.
                reversed_orientation=geo.get('reflection_reverses_orientation')
                result['checks'].append(check('h04.reflection_correspondence','pass'if reversed_orientation is True else 'fail'if reversed_orientation is False else 'unknown',
                    {'instance':annotation['roles']['reflection_head'].get('instance'),'relative_transform':geo.get('reflection_transform'),'orientation_reversed':reversed_orientation},'H04-MIRROR'))
            else:
                geo=ascii_geometry(frames,annotation);save(output/'geometry.json',geo)
                for identifier,ok,observed,group in [
                    ('h04.object_identity',geo['object_identity_consistent'],geo['frames'],'H04-OBJECTS'),
                    ('h04.uphill_motion',geo['uphill_continuity'],geo['frames'],'H04-MOTION'),
                    ('h04.contact_support',all(f['person_supported']and f['crate_supported']and f['push_chain_connected']for f in geo['frames']),geo['frames'],'H04-CONTACT')]:
                    status='pass'if ok else'unknown'if identifier=='h04.object_identity'else'fail'
                    result['checks'].append(check(identifier,status,observed,group))
            result['artifacts'].append({'path':str(output/'geometry.json'),'media_type':'application/json','purpose':'Computed geometry from source-bound roles'})
        else:
            result['checks'].append(check('h04.semantic_geometry','unknown',None,'H04-GEOMETRY',reason='No valid source-bound semantic object map; extraction/rendering alone cannot pass the task.'))
        result['artifacts'].append({'path':str(artifact),'media_type':'image/svg+xml','purpose':'Original SVG or original-character ASCII display'})
        for row in result['checks']:
            if row['id'] in {'h04.tie_contact','h04.reflection_in_mirror','h04.reflection_correspondence','h04.object_identity','h04.uphill_motion','h04.contact_support'}:
                row['evidence']=[{'path':str(output/'geometry.json'),'note':'Computed from selected original geometry/cells; conditional on semantic roles.'}]
                row['evidence_origin']='conditional_geometry'
                row['geometry_roles_origin']='prior_sha_bound_review'if trusted else'proposed_unverified_semantics'
                row['source_sha256']=digest
                row['semantic_certification']=False
                row['metric_status']=row['status']
                row['limits']='Selected shape/cell relations only; nonintersection does not by itself establish absent action, invalid occlusion, or failed mirror semantics.'
                if not trusted and row['status']=='fail':
                    row['status']='unknown'
                    row['reason']='The selected geometry lacks the tested relation; this is not a certified semantic task failure.'
            elif row['id']=='h04.frame_structure':row['evidence']=[{'path':str(output/'frames.json'),'pointer':'/frames'}]
            elif row['id'] in {'h04.semantic_objects','h04.proposal_binding'} and annotation:row['evidence']=[{'path':str(output/'accepted-proposal.json'),'note':'SHA-bound role locations; origin is explicitly recorded.'}]
            elif row['id']=='h04.actual_render':row['evidence']=[{'path':p}for p in initial.get('screenshots',[])]
        if 'visual_assessment'in result:
            from .assessment_quality import summarize
            assessment=result['visual_assessment'];controller=assessment.get('controller',{})
            assessment['quality']=summarize(assessment,lane='visual',controller_reviews=controller.get('reviews',[]),
                reviewer=controller.get('reviewer'),objective_checks=result['checks'],source_sha256=digest)
            assessment_path=output/'visual-assessment.json';save(assessment_path,assessment)
            result['assessment_quality']=assessment['quality']
            result['model_assessed_checks']=visual_assessment.assessment_checks(assessment,assessment_path)
            judgments={row['feature_id']:row['value']for row in result['visual_assessment'].get('observations',[])}
            pairs={'h04.tie_contact':'tie_adjustment','h04.reflection_in_mirror':'reflection_relation',
                   'h04.reflection_correspondence':'reflection_relation','h04.uphill_motion':'uphill_action',
                   'h04.object_identity':'identity_continuity','h04.contact_support':'contact_support'}
            result['assessment_geometry_differences']=[{'feature_id':pairs[row['id']],'geometry_check':row['id'],
                'model_assessed_value':judgments[pairs[row['id']]],'selected_geometry_metric':row.get('metric_status'),
                'interpretation':'Different evidence surfaces; geometry approximation or visual assessment may explain the difference, without choosing either as semantic truth.'}
                for row in result['checks']if row['id']in pairs and judgments.get(pairs[row['id']])in{'satisfied','not_satisfied'}
                and ((judgments[pairs[row['id']]]=='satisfied'and row.get('metric_status')=='fail')or(judgments[pairs[row['id']]]=='not_satisfied'and row.get('metric_status')=='pass'))]
        result['execution'].update(sandbox=initial.get('network_sandbox',{'verified':False}),network_calls=loopback_total,external_network_calls=0,environment_inherited=False,limits=initial.get('limits'))
        if cancelled()or initial.get('driver_status')=='cancelled':result['status']='cancelled'
        elif initial.get('driver_status')=='unsupported':result['status']='unsupported'
        elif any(c['status']=='fail'for c in result['checks']):result['status']='failed'
        elif any(c.get('mandatory')and c['status']=='unknown'for c in result['checks']):result['status']='limited'
        else:result['status']='completed'
    except (ValueError,OSError,UnicodeError,ET.ParseError)as exc:
        result['checks'].append(check('h04.input_or_runtime','unknown',None,'H04-ENVIRONMENT',reason=str(exc)))
    finally:
        result['execution']['elapsed_seconds']=round(time.monotonic()-start,4);save(output/'task-result.json',result)
    return result
