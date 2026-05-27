extension radius
extension containerImages
extension containers as ctnrs

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('Tag for the produced image. Required because the build source is a remote git URL.')
param imageTag string

@description('Git URL the recipe clones inside the cluster to build from.')
param buildSource string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'demo'
  properties: {
    environment: environment
  }
}

// Build and push the container image. Registry credentials are a
// platform-engineer concern: the PE wired `registrySecretName` into
// the recipe pack (see platform.bicep), so this resource carries no
// secret reference at all.
resource demoImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'demo-image'
  properties: {
    environment: environment
    application: app.id
    tag: imageTag
    build: {
      source: buildSource
    }
  }
}

resource demo 'ctnrs:Radius.Compute/containers@2025-08-01-preview' = {
  name: 'demo'
  properties: {
    environment: environment
    application: app.id
    containers: {
      demo: {
        image: demoImage.properties.imageReference
        ports: {
          web: {
            containerPort: 3000
          }
        }
      }
    }
    connections: {
      demoContainerImage: {
        source: demoImage.id
      }
    }
  }
}
