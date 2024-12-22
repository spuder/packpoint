Tindie api does not allow for direct download of the packaging slip 'pdf' (even though it really isn't a pdf)
you must provide a session cookie

```
curl -L -H "User-Agent: Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36" -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8" -H "Cookie: sessionid=xxxxx; csrftoken=xxxxx" 'https://www.tindie.com/orders/print/XXXX/' -o output.html
```