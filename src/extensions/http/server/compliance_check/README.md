## Compliance Check for HTTP/1.1 specification

Tina HTTP runs compliance checks for any major significant change. It uses [uNetworking/h1spec](https://github.com/uNetworking/h1spec) and runs it against the [test_server.odin](./test_server.odin). 

**Compliance result as of 7th May, 2026:** *33/33*

You can run the test yourself by following these steps:

- start the Tina HTTP server using `odin run .`
- Download or clone the [h1spec repo](https://github.com/uNetworking/h1spec)
- Open a separate terminal and run `deno run --allow-net http_test.ts 127.0.0.1 8080`

You should get something similar to the following:

```
✅ Request without HTTP version: Response Status Code 505, Expected ranges: [[400,599]]
✅ Request with Expect header: Response Status Code 200, Expected ranges: [[100,100],[200,299]]
✅ Valid GET request: Response Status Code 200, Expected ranges: [[200,299]]
✅ Valid GET request with edge cases: Response Status Code 200, Expected ranges: [[200,299]]
✅ Invalid header characters: Response Status Code 400, Expected ranges: [[400,499]]
✅ Missing Host header: Response Status Code 400, Expected ranges: [[400,499]]
✅ Multiple Host headers: Response Status Code 400, Expected ranges: [[400,499]]
✅ Overflowing negative Content-Length header: Response Status Code 400, Expected ranges: [[400,499]]
✅ Negative Content-Length header: Response Status Code 413, Expected ranges: [[400,499]]
✅ Non-numeric Content-Length header: Response Status Code 413, Expected ranges: [[400,499]]
✅ Empty header value: Response Status Code 200, Expected ranges: [[200,299]]
✅ Header containing invalid control character: Response Status Code 400, Expected ranges: [[400,499]]
✅ Invalid HTTP version: Response Status Code 505, Expected ranges: [[400,499],[500,599]]
✅ Invalid prefix of request: Response Status Code 505, Expected ranges: [[400,499],[500,599]]
✅ Invalid line ending: Response Status Code 400, Expected ranges: [[400,499]]
✅ Valid POST request with body: Response Status Code 200, Expected ranges: [[200,299],[404,404]]
✅ Chunked Transfer-Encoding: Response Status Code 200, Expected ranges: [[200,299]]
✅ Conflicting Transfer-Encoding and Content-Length in varying case: Response Status Code 400, Expected ranges: [[400,499],[200,299]]
✅ Fragmented method: Server waited successfully
✅ Fragmented URL 1: Server waited successfully
✅ Fragmented URL 2: Server waited successfully
✅ Fragmented URL 3: Server waited successfully
✅ Fragmented HTTP version: Server waited successfully
✅ Fragmented request line: Server waited successfully
✅ Fragmented request line newline 1: Server waited successfully
✅ Fragmented request line newline 2: Server waited successfully
✅ Fragmented field name: Server waited successfully
✅ Fragmented field value 1: Server waited successfully
✅ Fragmented field value 2: Server waited successfully
✅ Fragmented field value 3: Server waited successfully
✅ Fragmented field value 4: Server waited successfully
✅ Fragmented request: Server waited successfully
✅ Fragmented request termination: Server waited successfully

33 out of 33 tests passed.
```
