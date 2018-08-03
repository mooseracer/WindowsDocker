# traefik on Windows
The traefik project (https://github.com/containous/traefik) releases 64-bit Windows binaries that function on Server 2016. Dockerfile courtesy of https://github.com/StefanScherer.

We're running it as a container so that it can directly access the overlay network, which means we don't have to worry about port mappings for any of the backends. This sample traefik.toml enables the Docker provider.

### Build and Configure
Download Dockerfile and traefik.toml to C:\traefik. Build traefik:

    docker build -t traefik:latest


Set the Docker provider in traefik.toml:

    [docker]
      endpoint = "tcp://<host IP address>:2375"
      domain = "docker.localhost"
      watch = true
      swarmmode = true
      exposedByDefault = true
Where "endpoint" should be the external IP address of your Docker host, matching the contents of daemon.json. "domain" should be the name of the domain your hosts are joined to.

### Run 
Start traefik:

    docker run -d -v c:/traefik:C:/etc/traefik `
     -p 80:80 -p 443:443 -p 8080:8080 `
     --network traefik-net `
     --restart always `
     --name traefik `
    traefik:latest
Here's the breakdown:
Runs the container in detached mode; maps C:\traefik on the host to C:\etc\traefik on the container; maps three ports on the host to the same ports on the container; attaches it to the overlay network 'traefik-net'; sets the restart policy to 'always' so the container comes back when dockerd restarts or the container fails a healthcheck; names the container 'traefik'; uses the docker image tagged 'traefik:latest'

### Labels
traefik's Docker provider works because it's looking for containers or services with particular labels. For our purposes we'll focus on the latter. Here's an example docker-compose.yml:

    version: "3.3"
    
    services:
      myservice:
        image: microsoft/iis
        networks:
          - traefik-net
        deploy:
          labels:
            - "traefik.docker.network=traefik-net"
            - "traefik.port=80"
            - "traefik.enable=true"
            - "traefik.backend=myservice"
            - "traefik.backend.loadbalancer.method=wrr"
            - "traefik.frontend.entryPoints=http"
            - "traefik.frontend.rule=Host:myservice.apps.local"
    
    networks:
      traefik-net:
        external: true
Note that the labels are in the 'deploy' section. When you use **docker stack deploy** to stand this up, you can see the labels under **docker service inspect stackname_myservice**. It's important to bind this service to the network traefik-net, so that traefik can communicate with the container.

| Label | Purpose |
|--|--|
| traefik.port=80 | The port on the container traefik tries to connect to |
| traefik.frontend.entryPoints=http | Which traefik listener to use; matches up with the [entryPoints] section of traefik.toml |
| traefik.frontend.rule=Host:myservice.apps.local | Incoming requests that match 'myservice.apps.local' will be sent to the backend |
| traefik.backend=myservice | All container IPs will be assigned by traefik to a backend named 'myservice' |

The  [official documentation](https://docs.traefik.io/configuration/backends/docker/) has all the available labels, but the above are the most important you'll need to specify for every service.

## SSL
You can use openssl to generate a CSR. Make sure to specify a Subject Alternative Name -- if it's a wildcard (i.e. *.apps.local) you can provide https for every possible frontend rule coming in.

Have a CA provide you with a Base64 certificate. Place the key file (from openssl) and the certificate file (from the CA) under your \traefik folder on the host, then modify the config file.

traefik.toml:

    defaultEntryPoints = ["http","https"]
    [entryPoints]
      [entryPoints.http]
        address = ":80"
      [entryPoints.https]
        address = ":443"
        [entryPoints.https.tls]
        minVersion = "VersionTLS12"
        [[entryPoints.https.tls.certificates]]
          certFile = "/etc/traefik/myCertificate.cer"
          keyFile = "/etc/traefik/myKey.key"

Restart the traefik container. Update your app's docker-compose.yml to include the https entrypoint, and redeploy it.

     - "traefik.frontend.entryPoints=http,https"

Your traefik dashboard should update to reflect the new entrypoint, and you should be able to browse to your frontend rule with https.