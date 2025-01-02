<p align=center>
    <img src="./images/logo.png" width="200">
</p>


# PackPoint

The shipping station software for Tindie / Easy Post




## Usage

Create a `.env` file with your settings. You can use the provided examples. 

`cp .env.sample .env`


Then start the server
`rackup`

localhost:9292

## Development
```
APP_ENV=development rackup
```



## Production
```
APP_ENV=production RACK_ENV=production bundle exec rackup --host 0.0.0.0
```

## Production Docker/Podman

```bash
podman build -t spuder/packpoint . 
podman run  --env-file .env -e APP_ENV=production -e RACK_ENV=production -p 9292:9292 localhost/spuder/packpoint:latest
```

## Example
This example uses Faker to generate dummy addresses and usernames. 

![](images/demo2.png)