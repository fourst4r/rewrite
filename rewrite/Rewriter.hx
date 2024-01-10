package rewrite;

import haxe.io.Bytes;
import haxeparser.HaxeParser;
import haxe.macro.Expr;

using haxe.macro.ExprTools;
using StringTools;
using Lambda;

enum abstract Meta(String) to String
{
    final Wildcard = ":rewrite.wildcard";
}

class Rewriter
{
    var _wildcards:Map<String, Expr>;
    var _pattern:Expr;
    var _replacement:Expr;

    public function new(syntax:String)
    {
        final syntax = ~/#([0-9]+)/g.replace(syntax, '@${Meta.Wildcard}("$1")x');

        switch (syntax.split("==>"))
        {
            case [pattern, replacement]:
                _pattern = new HaxeParser(byte.ByteData.ofString(pattern), "").expr();
                _replacement = new HaxeParser(byte.ByteData.ofString(replacement), "").expr();
            default:
                throw "invalid rewrite syntax: expected 'pattern ==> replacement'";
        }
    }

    public function rewrite(src:Bytes)
    {   
        final parser = new HaxeParser(byte.ByteData.ofBytes(src), "");
        return replace(parser.expr());
    }

    function replace(e:Expr)
    {
        _wildcards = [];
        if (isMatch(_pattern, e))
            e = substitute(_replacement);

        return e.map(replace);
    }

    function substitute(e:Expr)
    {
        return switch (e.expr)
        {
            case EMeta({name:meta, params:[_.expr => EConst(CString(id,_))]}, _) if (meta == Meta.Wildcard):
                _wildcards[id].map(substitute);
            default: 
                e.map(substitute);
        }
    }
    
    function isMatch(pattern:Expr, value:Expr):Bool
    {
        function handleWildcard(id)
        {
            return if (_wildcards.exists(id))
                isMatch(_wildcards[id], value);
            else
            {
                _wildcards[id] = value;
                true;
            }
        }

        return switch ([pattern?.expr, value?.expr]) 
        {
            case [null,null]:
                true;
            case [null,_] | [_,null]:
                false;
            case [EBreak, EBreak] | [EContinue, EContinue]:
                true;
            case [EConst(c1), EConst(c2)]:
                c1 == c2;
            case [EWhile(c1, e1, n1), EWhile(c2, e2, n2)]:
                n1 == n2 && isMatch(c1, c2) && isMatch(e1, e2);
            case [EArray(e1,e2), EArray(f1,f2)] | [EFor(e1,e2), EFor(f1,f2)]:
                isMatch(e1, f1) && isMatch(e2, f2);
            case [EUnop(o1, p1, e1), EUnop(o2, p2, e2)]:
                o1 == o2 && p1 == p2 && isMatch(e1, e2);
            case [EBinop(o1, e1, e2), EBinop(o2, f1, f2)]:
                o1 == o2 && isMatch(e1, f1) && isMatch(e2, f2);
            case [EField(e1, f1, k1), EField(e2, f2, k2)]: 
                f1 == f2 && k1 == k2 && isMatch(e1, e2);
            case [EParenthesis(e1), EParenthesis(e2)]
               | [EUntyped(e1), EUntyped(e2)] 
               | [EThrow(e1), EThrow(e2)] 
               | [EDisplay(e1,_), EDisplay(e2,_)] 
               | [EMeta(_,e1), EMeta(_,e2)]
               | [EReturn(e1), EReturn(e2)]:
                isMatch(e1, e2);
            case [EVars(v1), EVars(v2)]:
                if (v1.length != v2.length)
                    return false;
                for (i in 0...v1.length)
                {
                    // TODO: handle v1[i].meta
                    for (m in v1[i].meta) switch (m)
                    {
                        case {name:meta, params:[_.expr => EConst(CString(id,_))]} if (meta == Meta.Wildcard):
                            if (!handleWildcard(id))
                                return false;
                        default:
                    }

                    if (!isMatch(v1[i].expr, v2[i].expr)
                        || v1[i].isFinal != v2[i].isFinal
                        || v1[i].isStatic != v2[i].isStatic
                        || v1[i].name != v2[i].name
                        || v1[i].type != v2[i].type)
                    {
                        return false;
                    }
                }
                true;
            case [ECheckType(e1, t1), ECheckType(e2, t2)] 
               | [EIs(e1, t1), EIs(e2, t2)]
               | [ECast(e1, t1), ECast(e2, t2)]:
               t1 == t2 && isMatch(e1, e2);
            case [ETry(e1, c1), ETry(e2, c2)]:
                if (c1.length != c2.length)
                    return false;
                for (i in 0...c1.length)
                {
                    if (!isMatch(c1[i].expr, c2[i].expr)
                        || c1[i].name != c2[i].name
                        || c1[i].type != c2[i].type)
                    {
                        return false;
                    }
                }
                isMatch(e1, e2);
            case [EIf(e1,e2,e3), EIf(f1,f2,f3)]
               | [ETernary(e1,e2,e3), ETernary(f1,f2,f3)]:
                isMatch(e1, f1) && isMatch(e2, f2) && isMatch(e3, f3);
            case [EArrayDecl(e1), EArrayDecl(e2)]
               | [EBlock(e1), EBlock(e2)]:
                if (e1.length != e2.length)
                    return false;
                for (i in 0...e1.length)
                    if (!isMatch(e1[i], e2[i]))
                        return false;
                true;
            case [ENew(t1, p1), ENew(t2, p2)]:
                if (t1 != t2 || p1.length != p2.length)
                    return false;
                for (i in 0...p1.length)
                    if (!isMatch(p1[i], p2[i]))
                        return false;
                true;
            case [EObjectDecl(f1), EObjectDecl(f2)]:
                if (f1.length != f2.length)
                    return false;
                for (i in 0...f1.length)
                    if (!isMatch(f1[i].expr, f2[i].expr)
                        || f1[i].field != f2[i].field
                        || f1[i].quotes != f2[i].quotes)
                    {
                        return false;
                    }
                true;
            case [ECall(e1, p1), ECall(e2, p2)]:
                if (p1.length != p2.length || !isMatch(e1, e2))
                    return false;
                for (i in 0...p1.length)
                    if (!isMatch(p1[i], p2[i]))
                        return false;
                true;
            case [EFunction(k1, f1), EFunction(k2, f2)]:
                if (k1 != k2 || f1.args.length != f2.args.length)
                    return false;
                for (i in 0...f1.args.length)
                    // TODO: handle f1.args[i].meta
                    if (!isMatch(f1.args[i].value, f2.args[i].value)
                        || f1.args[i].name != f2.args[i].name
                        || f1.args[i].opt != f2.args[i].opt
                        || f1.args[i].type != f2.args[i].type)
                    {
                        return false;
                    }
                function matchParams(p1:Null<Array<TypeParamDecl>>, p2:Null<Array<TypeParamDecl>>)
                {
                    if (p1 == null && p2 == null)
                        return true;
                    if (p1?.length != p2?.length)
                        return false;
                    for (i in 0...p1.length)
                    {
                        // TODO: handle p1[i].meta
                        if (p1[i].constraints.length != p2[i].constraints.length)
                            return false;
                        for (j in 0...p1[i].constraints.length)
                            if (p1[i].constraints[j] != p2[i].constraints[j])
                                return false;
                        if (p1[i].defaultType != p2[i].defaultType
                            || p1[i].name != p2[i].name
                            || !matchParams(p1[i].params, p2[i].params))
                        {
                            return false;
                        }
                    }
                    return true;
                }
                return matchParams(f1.params, f2.params);
            case [ESwitch(e1, c1, d1), ESwitch(e2, c2, d2)]:
                if (c1.length != c2.length || !isMatch(e1, e2) || !isMatch(d1, d2))
                    return false;
                for (i in 0...c1.length)
                {
                    if (c1[i].values.length != c2[i].values.length
                        || !isMatch(c1[i].expr, c2[i].expr)
                        || !isMatch(c1[i].guard, c2[i].guard))
                    {
                        return false;
                    }
                    for (j in 0...c1[i].values.length)
                        if (!isMatch(c1[i].values[j], c2[i].values[j]))
                            return false;
                }
                true;
            case [EMeta({name:meta, params:[_.expr => EConst(CString(id,_))]}, _), _] if (meta == Meta.Wildcard):
                handleWildcard(id);
            case [EMeta(_,e1), _]: 
                isMatch(e1, value);
            case [_, EMeta(_,e2)]: 
                isMatch(pattern, e2);
            default:
                false;
        }
    }
}