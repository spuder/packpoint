Tindie api does not allow for direct download of the packaging slip 'pdf' (even though it really isn't a pdf)
you must provide a session cookie

```
curl -L -H "User-Agent: Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36" -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8" -H "Cookie: sessionid=xxxxx; csrftoken=xxxxx" 'https://www.tindie.com/orders/print/XXXX/' -o output.html
```

Login

Theoretically you should be able to get a session token like this

```
curl -c cookies.txt -i https://www.tindie.com/accounts/login/

curl -b cookies.txt -c cookies.txt -i \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Referer: https://www.tindie.com/accounts/login/" \
  -d "username=YOUR_USERNAME&api_key=YOUR_API_KEY&csrfmiddlewaretoken=CSRF_TOKEN_FROM_STEP_1" \
  https://www.tindie.com/accounts/login/

curl -b cookies.txt -c cookies.txt -L \
  -H "User-Agent: Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36" \
  -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8" \
  'https://www.tindie.com/orders/print/XXXXX/' -o output.html

```