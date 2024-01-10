package rewrite;

class Main
{
    static function main()
    {
        final rewriter = new Rewriter("if (#1) #2 else #3 ==> #1 ? #2 : #3");
        rewriter.rewrite(haxe.io.Bytes.ofString("if (a) b else c"));
    }
}