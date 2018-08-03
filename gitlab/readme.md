# GitLab - Container Registry and CI/CD
This doc discusses integrating Docker Swarm with an existing private GitLab server, and gets you started with a very basic CI/CD example.

For help with getting GitLab up and running please see the [official documentation.](https://docs.gitlab.com/omnibus/) Mine is on Ubuntu 18.04, following the GitLab omnibus installation. Save yourself some time and ensure it's configured with a valid certificate, don't bother with self-signeds.

From a Docker host, make sure you can log in to your registry:

    docker login git.local:5005

## Tagging, Pushing, Pulling
Tagging images is how you tell Docker which registry they should be in, as well as specifying the version of the image. Let's take our traefik image and put it in GitLab.

Create a new project in GitLab, call it 'traefik'. In the project's Registry section you can see its address, i.e. git.local:5005/traefik.

Tag the traefik image with the new address:

    docker tag traefik git.local:5005/traefik
    docker images
Upload it to GitLab:

    docker push git.local:5005/traefik

Switch to a different Docker host. Log in to the registry again, then download your image:

    docker login git.local:5005
    docker pull git.local:5005/traefik

That's it. When referencing customized Docker images from Swarm you'll always want them to come from your container registry, so you don't have to worry about keeping track of whether a particular host has downloaded the right image or not.

## GitLab Runners
GitLab's CI/CD works based on sending commands to agents running on other systems. [Download](https://gitlab-runner-downloads.s3.amazonaws.com/latest/binaries/gitlab-runner-windows-amd64.exe) and [install](https://docs.gitlab.com/runner/install/windows.html) and [register](https://docs.gitlab.com/runner/register/index.html) the agent on a Docker host:

      gitlab-runner.exe install
      gitlab-runner.exe start
      gitlab-runner.exe register --non-interactive --locked="false" --name="$env:computername-PowerShell" --url="https://git.local/" --registration-token="abCdEfGHi6T9vB1JnM2B" --executor="shell" --shell="powershell"
Use your own GitLab registration token, found in GitLab > Admin Area > Runners.

Confirm registration:

    gitlab-runner.exe verify
    gitlab-runner.exe status
In GitLab you should see your new runner at the bottom.

## Sample Project: iisapp
In GitLab create a new project named 'iisapp'. It will be an uncustomized Microsoft image. Pull it from the Internet, and upload it to your registry as a "test" image:

    docker pull microsoft/iis
    docker tag microsoft/iis git.local:5005/iisapp:test
    docker push git.local:5005/iisapp:test
Download the docker-compose.yml and .gitlab-ci.yml files from this page. Modify the image name, GitLab server, and traefik frontend rule to reflect your environment. Commit them to your iisapp project.

As soon as .gitlab-ci.yml is committed, GitLab is going to initiate a new Pipeline for the project (GitLab > iisapp project > CI/CD). It will do so for every new commit. This .gitlab-ci.yml defined three stages, so you'll see an icon and progress for each. Drill down into them and you can watch the output from GitLab-Runner in real time. This is invaluable for troubleshooting.

Review the output from the Test stage; test.ps1 should have returned a 0 indicating success. Go to the Release stage and see that it's waiting on your approval to proceed. Approve it, and watch the Deploy stage as it uses docker-compose.yml to stand up iisapp in Swarm. traefik will soon show the new service, and you'll be able to browse to it using the frontend rule address.

## .gitlab-ci.yml
There's a lot of flexibility with how pipelines and jobs can be structured, so as always check out the [official documentation](https://docs.gitlab.com/ee/ci/yaml/). For this example we want it to start a container using our test image, see if it works, tag the test image as release, and then deploy the release image.

### Initialization
The 'stages:' section defines the structure of the pipeline. Each line here will require a corresponding "stage:" value below, and will execute them in order.
The 'variables:' section lets you specify custom variables that each stage can reference. Define them with "VARIABLENAME: value" and reference with "$VARIABLENAME".
'before_script' contains any commands the Runner should execute prior to any other stages. Usually this at least consists of logging in to the container registry.

### Test
There are different types of Runners, and their particular type will define how you code your stages. We configured our Runner to be of type shell, and set its shell type to PowerShell. Each line in the 'script:' section is an individual PowerShell command to be executed by our Runner.

    script:
    - docker pull $TEST_IMAGE
    - $test = .\test.ps1 "$SERVICE_NAME`_test" $TEST_IMAGE
    - Write-Host $test
Pretty simple: download the test image, execute test.ps1 with some parameters and output the result.

    #test.ps1
    #Start test container, try an HTTP GET, look for status 200
    param($SERVICE_NAME,  $IMAGE)
    $testCommand  = {Invoke-WebRequest  -UseBasicParsing http://localhost | Select StatusCode}
    docker run -d --name $SERVICE_NAME  $IMAGE
    start-sleep  -s 20
    $testResult  = docker exec $SERVICE_NAME  powershell.exe  -Command $testCommand
    docker rm $SERVICE_NAME  -f
    
    If ($testResult.StatusCode  -eq  "200") {Return  0}
    Else {Return  $testResult}
The test just starts the container and has it run Invoke-WebRequest against itself, then tears down the container. If the resulting HTTP status code is good (200 OK), return 0. Otherwise return what we got.

### Release
The release stage only has one task, to re-tag the test image as release and upload it back to GitLab. It has been specified with 'when: manual' to require your explicit approval to proceed with this stage and any subsequent stages.

### Deploy
This stage has the release image get deployed into Swarm using docker-compose.yml. Note the '--with-registry-auth' flag, which provides all other Swarm nodes with the login info needed to access the image from the container registry.

## Next Steps
There wasn't much of a Continuous Integration element to this example -- you didn't actually *build* anything. Try taking a different project of yours with a Dockerfile and adding a build stage :

    stage: build
    script:
      - docker build --pull -t $TEST_IMAGE .
      - docker push $TEST_IMAGE
And you can redefine TEST_IMAGE to automatically use the commit name:

    TEST_IMAGE: git.local:5005/yourProject:$CI_COMMIT_REF_NAME

Now you have a scenario where you can commit new code, and GitLab will automatically build a new container, test it, and deploy it.