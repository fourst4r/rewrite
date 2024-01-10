Small script that rewrites Haxe expressions with primitive pattern matching (*inspired by gofmt*).

**Pattern:** 
```js
if (#1) #2 else #3 ==> #1 ? #2 : #3
```
(note that "==>" is a magic syntax that separates the pattern from the replacement expression)

**Input:**
```haxe
if (a) b else c
``` 
transforms into 
```haxe
a ? b : c
```

