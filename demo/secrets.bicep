// Registry credentials, deployed separately from platform.bicep so
// the env + recipePack + secret form no symbolic cycle (BCP080).
// The recipePack wires `registrySecretName: 'ghcr-creds'` as a
// literal; this file is the one place the actual secret with that
// name is declared. Rotate by re-deploying this file alone.
//
// Deploy:
//   rad deploy secrets.bicep \
//     -p registryUsername=$GHCR_USER \
//     -p registryPassword=$GHCR_TOKEN

extension radius

@description('Registry username.')
param registryUsername string

@description('Registry password / PAT.')
@secure()
param registryPassword string

resource env 'Radius.Core/environments@2025-08-01-preview' existing = {
  name: 'default'
}

resource ghcrCreds 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'ghcr-creds'
  properties: {
    environment: env.id
    data: {
      username: {
        value: registryUsername
      }
      password: {
        value: registryPassword
      }
    }
  }
}
