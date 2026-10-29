## Chart backgrounds

Transparent charts must blend into this message surface. Explicit white stays white.

### vega-lite Null

```vega-lite
{"width":640,"height":100,"title":{"text":"vega-lite: null background","subtitle":"Title, ticks, legend and annotation stay readable","anchor":"start"},"background":null,"data":{"values":[{"category":"A","count":7},{"category":"B","count":3}]},"config":{"view":{"fill":null,"stroke":null},"legend":{"orient":"bottom"}},"encoding":{"x":{"field":"category","type":"nominal","title":null},"y":{"field":"count","type":"quantitative","title":"Count"}},"layer":[{"mark":"bar","encoding":{"color":{"field":"category","type":"nominal"}}},{"mark":{"type":"text","dy":-7},"encoding":{"text":{"field":"count"}}}]}
```

### vega-lite Omitted

```vega-lite
{"width":640,"height":100,"title":{"text":"vega-lite: omitted background","subtitle":"Title, ticks, legend and annotation stay readable","anchor":"start"},"data":{"values":[{"category":"A","count":7},{"category":"B","count":3}]},"config":{"view":{"fill":null,"stroke":null},"legend":{"orient":"bottom"}},"encoding":{"x":{"field":"category","type":"nominal","title":null},"y":{"field":"count","type":"quantitative","title":"Count"}},"layer":[{"mark":"bar","encoding":{"color":{"field":"category","type":"nominal"}}},{"mark":{"type":"text","dy":-7},"encoding":{"text":{"field":"count"}}}]}
```

### vega-lite White

```vega-lite
{"width":640,"height":100,"title":{"text":"vega-lite: white background","subtitle":"Title, ticks, legend and annotation stay readable","anchor":"start"},"background":"#ffffff","data":{"values":[{"category":"A","count":7},{"category":"B","count":3}]},"config":{"view":{"fill":null,"stroke":null},"legend":{"orient":"bottom"}},"encoding":{"x":{"field":"category","type":"nominal","title":null},"y":{"field":"count","type":"quantitative","title":"Count"}},"layer":[{"mark":"bar","encoding":{"color":{"field":"category","type":"nominal"}}},{"mark":{"type":"text","dy":-7},"encoding":{"text":{"field":"count"}}}]}
```

### vega Null

```vega
{"width":640,"height":100,"title":{"text":"vega: null background","subtitle":"Title, ticks, legend and annotation stay readable","anchor":"start"},"background":null,"data":[{"name":"points","values":[{"category":"A","count":7},{"category":"B","count":3}]}],"scales":[{"name":"x","type":"band","domain":{"data":"points","field":"category"},"range":"width","padding":0.3},{"name":"y","type":"linear","domain":{"data":"points","field":"count"},"range":"height","zero":true,"nice":true},{"name":"color","type":"ordinal","domain":["A","B"],"range":["#4c78a8","#f58518"]}],"axes":[{"scale":"x","orient":"bottom"},{"scale":"y","orient":"left","title":"Count","tickCount":4}],"legends":[{"fill":"color","orient":"bottom"}],"marks":[{"type":"rect","from":{"data":"points"},"encode":{"enter":{"x":{"scale":"x","field":"category"},"width":{"scale":"x","band":1},"y":{"scale":"y","field":"count"},"y2":{"scale":"y","value":0},"fill":{"scale":"color","field":"category"}}}},{"type":"text","from":{"data":"points"},"encode":{"enter":{"x":{"scale":"x","field":"category","band":0.5},"y":{"scale":"y","field":"count","offset":-7},"text":{"field":"count"},"align":{"value":"center"}}}}]}
```

### vega Omitted

```vega
{"width":640,"height":100,"title":{"text":"vega: omitted background","subtitle":"Title, ticks, legend and annotation stay readable","anchor":"start"},"data":[{"name":"points","values":[{"category":"A","count":7},{"category":"B","count":3}]}],"scales":[{"name":"x","type":"band","domain":{"data":"points","field":"category"},"range":"width","padding":0.3},{"name":"y","type":"linear","domain":{"data":"points","field":"count"},"range":"height","zero":true,"nice":true},{"name":"color","type":"ordinal","domain":["A","B"],"range":["#4c78a8","#f58518"]}],"axes":[{"scale":"x","orient":"bottom"},{"scale":"y","orient":"left","title":"Count","tickCount":4}],"legends":[{"fill":"color","orient":"bottom"}],"marks":[{"type":"rect","from":{"data":"points"},"encode":{"enter":{"x":{"scale":"x","field":"category"},"width":{"scale":"x","band":1},"y":{"scale":"y","field":"count"},"y2":{"scale":"y","value":0},"fill":{"scale":"color","field":"category"}}}},{"type":"text","from":{"data":"points"},"encode":{"enter":{"x":{"scale":"x","field":"category","band":0.5},"y":{"scale":"y","field":"count","offset":-7},"text":{"field":"count"},"align":{"value":"center"}}}}]}
```

### vega White

```vega
{"width":640,"height":100,"title":{"text":"vega: white background","subtitle":"Title, ticks, legend and annotation stay readable","anchor":"start"},"background":"#ffffff","data":[{"name":"points","values":[{"category":"A","count":7},{"category":"B","count":3}]}],"scales":[{"name":"x","type":"band","domain":{"data":"points","field":"category"},"range":"width","padding":0.3},{"name":"y","type":"linear","domain":{"data":"points","field":"count"},"range":"height","zero":true,"nice":true},{"name":"color","type":"ordinal","domain":["A","B"],"range":["#4c78a8","#f58518"]}],"axes":[{"scale":"x","orient":"bottom"},{"scale":"y","orient":"left","title":"Count","tickCount":4}],"legends":[{"fill":"color","orient":"bottom"}],"marks":[{"type":"rect","from":{"data":"points"},"encode":{"enter":{"x":{"scale":"x","field":"category"},"width":{"scale":"x","band":1},"y":{"scale":"y","field":"count"},"y2":{"scale":"y","value":0},"fill":{"scale":"color","field":"category"}}}},{"type":"text","from":{"data":"points"},"encode":{"enter":{"x":{"scale":"x","field":"category","band":0.5},"y":{"scale":"y","field":"count","offset":-7},"text":{"field":"count"},"align":{"value":"center"}}}}]}
```

End of background comparison.
