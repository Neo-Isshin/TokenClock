"""Candidate visible formatting descriptors; never a model identity classifier.

No code execution, semantic judge, reference lookup or hidden reasoning access.
These related descriptors share the same answer and must not become extra votes.
"""
import ast
import re

SCHEMA='tokenclock-candidate-style/v1'
DEFINITION={
    'layout':'plain / structured prose / code only / code with prose, using complete fenced blocks or a bare Python function',
    'markdown_heading':'ATX heading outside fenced blocks',
    'list_style':'none / bullet / ordered / mixed outside fenced blocks',
    'code_explanation_position':'none / before / after / both / between / not applicable',
    'function_annotations':'all / some / none / no Python function / unparsed code; syntax only',
    'evidence_group':'visible-answer-presentation; correlated, no independent votes',
    'not_measured':['correctness','hidden reasoning','model identity','tool behavior'],
}


def extract_style(answer,*,completed=True):
    if not isinstance(answer,str) or len(answer)>1024*1024:raise ValueError('A bounded text answer is required')
    if not completed or not answer.strip():return {'schema':SCHEMA,'status':'unavailable','features':{},'formal_direction_use':False}
    blocks=list(re.finditer(r'^([ \t]*)(`{3,}|~{3,})([^\n]*)\n([\s\S]*?)^\1\2[ \t]*$',answer,re.M))
    masked=answer
    for b in reversed(blocks):masked=masked[:b.start()]+'\n'+masked[b.end():]
    headings=bool(re.search(r'^ {0,3}#{1,6}\s+\S',masked,re.M))
    bullets=bool(re.search(r'^\s*[-*+]\s+\S',masked,re.M))
    ordered=bool(re.search(r'^\s*(?:\d+[.)]\s+|\d+[、）]\s*)\S',masked,re.M))
    features={'markdown_heading':headings,'list_style':'mixed' if bullets and ordered else 'bullet' if bullets else 'ordered' if ordered else 'none'}
    functions=[];unparsed=False
    snippets=[b.group(4) for b in blocks if b.group(3).strip().lower() in {'','python','py'}]
    if not blocks:snippets=[answer]
    for snippet in snippets:
        try:tree=ast.parse(snippet)
        except (SyntaxError,ValueError,RecursionError):
            if blocks:unparsed=True
            continue
        functions += [n for n in ast.walk(tree) if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))]
    bare_code=not blocks and bool(functions)
    if blocks or bare_code:
        before=bool(answer[:blocks[0].start()].strip()) if blocks else False
        after=bool(answer[blocks[-1].end():].strip()) if blocks else False
        middle=any(answer[a.end():b.start()].strip() for a,b in zip(blocks,blocks[1:]))
        features['layout']='code_with_prose' if (before or after or middle) else 'code_only'
        features['code_explanation_position']='both' if before and after else 'before' if before else 'after' if after else 'between' if middle else 'none'
    else:
        features['layout']='structured_prose' if headings or bullets or ordered else 'plain'
        features['code_explanation_position']='not_applicable'
    annotations=[]
    for fn in functions:
        args=list(fn.args.posonlyargs)+list(fn.args.args)+list(fn.args.kwonlyargs)
        if fn.args.vararg:args.append(fn.args.vararg)
        if fn.args.kwarg:args.append(fn.args.kwarg)
        annotations += [a.annotation is not None for a in args]+[fn.returns is not None]
    features['function_annotations']='unparsed_code' if unparsed else 'no_python_function' if not annotations else 'all' if all(annotations) else 'some' if any(annotations) else 'none'
    return {'schema':SCHEMA,'status':'observed','features':features,'formal_direction_use':False,
            'evidence_group':'visible-answer-presentation','semantic_correctness_checked':False}
