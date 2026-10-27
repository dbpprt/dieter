## Rich report

**Offline graphics**, _emphasis_, ~~removed~~ and `inline code`.

| Package        | Current | Fixed in | Severity | Advisory      | Importers | Notes                            |
| :------------- | ------: | -------: | :------: | :------------ | --------: | :------------------------------- |
| example/module |     1.0 |      1.1 |   high   | Inline report |        12 | Wide tables scroll independently |

- [x] Inline data prepared
- [ ] Review the report

> Charts work without a network connection.

### Mermaid workflow

```mermaid
flowchart LR
    A[Mail source] --> B[Offline preview]
```

### Vega-Lite chart

```vega-lite
{"data":{"values":[{"category":"Fixed","count":7},{"category":"Remaining","count":3}]},"mark":"bar","encoding":{"x":{"field":"category","type":"nominal"},"y":{"field":"count","type":"quantitative"}}}
```

### Alias chart

```vegalite
{"data":{"values":[{"category":"Alias","count":4}]},"mark":"bar","encoding":{"x":{"field":"category","type":"nominal"},"y":{"field":"count","type":"quantitative"}}}
```

### Vega chart

```vega
{"width":300,"height":120,"data":[{"name":"points","values":[{"x":20,"y":30},{"x":90,"y":70}]}],"marks":[{"type":"symbol","from":{"data":"points"},"encode":{"enter":{"x":{"field":"x"},"y":{"field":"y"},"size":{"value":200},"fill":{"value":"steelblue"}}}}]}
```

### Invalid chart keeps source

```vega-lite
{"data": broken JSON}
```

### Remote data stays blocked

```vega-lite
{"data":{"url":"https://example.invalid/private.csv"},"mark":"bar"}
```

```unknown-chart
Readable unsupported source
```

<script>document.body.textContent = "HTML executed"</script>

![Remote image alt text](https://example.invalid/tracker.png)

[Workspace README](README.md) · [Outside workspace](file:///escape.txt) · [Unsafe link](<javascript:alert(1)>)

End of offline report.
