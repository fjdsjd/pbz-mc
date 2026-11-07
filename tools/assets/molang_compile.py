"""Parse the finite Molang expressions used by pinned vanilla mob animations.

Emits data, never Python/Lua eval. Rejects unconsumed/unknown syntax at build time.
"""
import re
import json
def read_json(raw):
    if isinstance(raw,bytes):raw=raw.decode('utf-8-sig')
    raw=re.sub(r'"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*[\s\S]*?\*/',
               lambda m:m[0]if m[0].startswith('"')else '',raw)
    raw=re.sub(r'"(?:\\.|[^"\\])*"|,\s*(?=[}\]])',lambda m:''if m[0].startswith(',')else m[0],raw)
    return json.loads(raw)
TOKEN=re.compile(r"\s*(?:(\d+(?:\.\d*)?(?:e[+-]?\d+)?f?|\.\d+(?:e[+-]?\d+)?f?)|([a-z_][\w.]*)|('(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\")|(\?\?|&&|\|\||==|!=|<=|>=|[+*/%?:;,(){}!<>=\-]))",re.I)
PRECEDENCE={'=':1,'??':3,'||':4,'&&':5,'==':6,'!=':6,'<':7,'>':7,'<=':7,'>=':7,'+':8,'-':8,'*':9,'/':9,'%':9}
class Parser:
    def __init__(self,text):
        self.tokens=[];self.i=0;cursor=0
        while cursor<len(text.rstrip()):
            m=TOKEN.match(text,cursor)
            if not m:raise ValueError('Molang token: '+text[cursor:])
            a,b,c,d=m.groups();self.tokens.append(float(a.rstrip('fF')) if a else b.lower() if b else c if c else d);cursor=m.end()
        self.tokens.append('<end>')
    def pop(self):v=self.tokens[self.i];self.i+=1;return v
    def peek(self):return self.tokens[self.i]
    def expect(self,t):assert self.pop()==t,t
    def sequence(self,closing='<end>'):
        result=[]
        while self.peek()!=closing:
            if self.peek()==';':self.pop();continue
            if self.peek()=='return':self.pop();result.append(['return',self.expression()])
            else:result.append(self.expression())
            if self.peek()==';':self.pop()
            else:assert self.peek()==closing,(self.peek(),closing)
        return result[0] if len(result)==1 else ['seq',*result]
    def expression(self,minimum=0):
        t=self.pop()
        if isinstance(t,float):left=t
        elif t[0] in "'\"":left=['str',t[1:-1]]
        elif t in ('-','+','!'):left=['unary',t,self.expression(10)]
        elif t=='(':left=self.expression();self.expect(')')
        elif t=='{':left=self.sequence('}');self.expect('}')
        else:
            assert re.fullmatch(r'[a-z_][\w.]*',t),t
            t=re.sub(r'^v\.', 'variable.',t);t=re.sub(r'^q\.', 'query.',t);t=re.sub(r'^t\.', 'temp.',t)
            left=['get',t]
            if self.peek()=='(':
                self.pop();args=[]
                while self.peek()!=')':
                    args.append(self.expression())
                    if self.peek()!=',':break
                    self.pop()
                self.expect(')');left=['call',t,*args]
        while True:
            op=self.peek()
            if op=='?' and minimum<=2:
                self.pop();yes=self.expression(0)
                no=0
                if self.peek()==':':self.pop();no=self.expression(2)
                left=['if',left,yes,no];continue
            p=PRECEDENCE.get(op,0)
            if not p or p<minimum:break
            self.pop();right=self.expression(p if op=='=' else p+1)
            if op=='=':
                assert isinstance(left,list)and left[0]=='get'and left[1].startswith(('variable.','temp.')),left
                left=['set',left[1],right]
            else:left=[op,left,right]
        return left
def parse(value):
    if isinstance(value,(float,int)):return value
    p=Parser(value);result=p.sequence();p.expect('<end>');return result
