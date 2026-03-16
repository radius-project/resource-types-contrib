// Variables (using var instead of parameters since the ARM template uses variables)
var cgProfileName = 'cgp_1'
var nGroupsName = 'ngroup_confidential_basic'
var apiVersion = '2024-09-01-preview'
var desiredCount = 1
var prefixCG = 'cg-confidential-'
var resourcePrefix = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/'

@description('Radius ACI Container Context')
param context object

// Output the context object for debugging
output contextObject object = context

// Container Group Profile with Confidential Computing
resource containerGroupProfile 'Microsoft.ContainerInstance/containerGroupProfiles@2024-09-01-preview' = {
  name: cgProfileName
  location: resourceGroup().location
  properties: {
    sku: 'Confidential'
    confidentialComputeProperties: {
      ccePolicy: 'cGFja2FnZSBwb2xpY3kKCmltcG9ydCBmdXR1cmUua2V5d29yZHMuZXZlcnkKaW1wb3J0IGZ1dHVyZS5rZXl3b3Jkcy5pbgoKYXBpX3ZlcnNpb24gOj0gIjAuMTAuMCIKZnJhbWV3b3JrX3ZlcnNpb24gOj0gIjAuMi4zIgoKZnJhZ21lbnRzIDo9IFsKICB7CiAgICAiZmVlZCI6ICJtY3IubWljcm9zb2Z0LmNvbS9hY2kvYWNpLWNjLWluZnJhLWZyYWdtZW50IiwKICAgICJpbmNsdWRlcyI6IFsKICAgICAgImNvbnRhaW5lcnMiLAogICAgICAiZnJhZ21lbnRzIgogICAgXSwKICAgICJpc3N1ZXIiOiAiZGlkOng1MDk6MDpzaGEyNTY6SV9faXVMMjVvWEVWRmRUUF9hQkx4X2VUMVJQSGJDUV9FQ0JRZllacHQ5czo6ZWt1OjEuMy42LjEuNC4xLjMxMS43Ni41OS4xLjMiLAogICAgIm1pbmltdW1fc3ZuIjogIjQiCiAgfQpdCgpjb250YWluZXJzIDo9IFt7ImFsbG93X2VsZXZhdGVkIjpmYWxzZSwiYWxsb3dfc3RkaW9fYWNjZXNzIjp0cnVlLCJjYXBhYmlsaXRpZXMiOnsiYW1iaWVudCI6W10sImJvdW5kaW5nIjpbIkNBUF9DSE9XTiIsIkNBUF9EQUNfT1ZFUlJJREUiLCJDQVBfRlNFVElEIiwiQ0FQX0ZPV05FUiIsIkNBUF9NS05PRCIsIkNBUF9ORVRfUkFXIiwiQ0FQX1NFVEdJRCIsIkNBUF9TRVRVSUQiLCJDQVBfU0VURkNBUCIsIkNBUF9TRVRQQ0FQIiwiQ0FQX05FVF9CSU5EX1NFUlZJQ0UiLCJDQVBfU1lTX0NIUk9PVCIsIkNBUF9LSUxMIiwiQ0FQX0FVRElUX1dSSVRFIl0sImVmZmVjdGl2ZSI6WyJDQVBfQ0hPV04iLCJDQVBfREFDX09WRVJSSURFIiwiQ0FQX0ZTRVRJRCIsIkNBUF9GT1dORVIiLCJDQVBfTUtOT0QiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRHSUQiLCJDQVBfU0VUVUlEIiwiQ0FQX1NFVEZDQVAiLCJDQVBfU0VUUENBUCIsIkNBUF9ORVRfQklORF9TRVJWSUNFIiwiQ0FQX1NZU19DSFJPT1QiLCJDQVBfS0lMTCIsIkNBUF9BVURJVF9XUklURSJdLCJpbmhlcml0YWJsZSI6W10sInBlcm1pdHRlZCI6WyJDQVBfQ0hPV04iLCJDQVBfREFDX09WRVJSSURFIiwiQ0FQX0ZTRVRJRCIsIkNBUF9GT1dORVIiLCJDQVBfTUtOT0QiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRHSUQiLCJDQVBfU0VUVUlEIiwiQ0FQX1NFVEZDQVAiLCJDQVBfU0VUUENBUCIsIkNBUF9ORVRfQklORF9TRVJWSUNFIiwiQ0FQX1NZU19DSFJPT1QiLCJDQVBfS0lMTCIsIkNBUF9BVURJVF9XUklURSJdfSwiY29tbWFuZCI6WyIvcGF1c2UiXSwiZW52X3J1bGVzIjpbeyJwYXR0ZXJuIjoiUEFUSD0vdXNyL2xvY2FsL3NiaW46L3Vzci9sb2NhbC9iaW46L3Vzci9zYmluOi91c3IvYmluOi9zYmluOi9iaW4iLCJyZXF1aXJlZCI6dHJ1ZSwic3RyYXRlZ3kiOiJzdHJpbmcifSx7InBhdHRlcm4iOiJURVJNPXh0ZXJtIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InN0cmluZyJ9XSwiZXhlY19wcm9jZXNzZXMiOltdLCJsYXllcnMiOlsiMTZiNTE0MDU3YTA2YWQ2NjVmOTJjMDI4NjNhY2EwNzRmZDU5NzZjNzU1ZDI2YmZmMTYzNjUyOTkxNjllODQxNSJdLCJtb3VudHMiOltdLCJuYW1lIjoicGF1c2UtY29udGFpbmVyIiwibm9fbmV3X3ByaXZpbGVnZXMiOmZhbHNlLCJzZWNjb21wX3Byb2ZpbGVfc2hhMjU2IjoiIiwic2lnbmFscyI6W10sInVzZXIiOnsiZ3JvdXBfaWRuYW1lcyI6W3sicGF0dGVybiI6IiIsInN0cmF0ZWd5IjoiYW55In1dLCJ1bWFzayI6IjAwMjIiLCJ1c2VyX2lkbmFtZSI6eyJwYXR0ZXJuIjoiIiwic3RyYXRlZ3kiOiJhbnkifX0sIndvcmtpbmdfZGlyIjoiLyJ9LHsiYWxsb3dfZWxldmF0ZWQiOmZhbHNlLCJhbGxvd19zdGRpb19hY2Nlc3MiOnRydWUsImNhcGFiaWxpdGllcyI6eyJhbWJpZW50IjpbXSwiYm91bmRpbmciOlsiQ0FQX0FVRElUX1dSSVRFIiwiQ0FQX0NIT1dOIiwiQ0FQX0RBQ19PVkVSUklERSIsIkNBUF9GT1dORVIiLCJDQVBfRlNFVElEIiwiQ0FQX0tJTEwiLCJDQVBfTUtOT0QiLCJDQVBfTkVUX0JJTkRfU0VSVklDRSIsIkNBUF9ORVRfUkFXIiwiQ0FQX1NFVEZDQVAiLCJDQVBfU0VUR0lEIiwiQ0FQX1NFVFBDQVAiLCJDQVBfU0VUVUlEIiwiQ0FQX1NZU19DSFJPT1QiXSwiZWZmZWN0aXZlIjpbIkNBUF9BVURJVF9XUklURSIsIkNBUF9DSE9XTiIsIkNBUF9EQUNfT1ZFUlJJREUiLCJDQVBfRk9XTkVSIiwiQ0FQX0ZTRVRJRCIsIkNBUF9LSUxMIiwiQ0FQX01LTk9EIiwiQ0FQX05FVF9CSU5EX1NFUlZJQ0UiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRGQ0FQIiwiQ0FQX1NFVEdJRCIsIkNBUF9TRVRQQ0FQIiwiQ0FQX1NFVFVJRCIsIkNBUF9TWVNfQ0hST09UIl0sImluaGVyaXRhYmxlIjpbXSwicGVybWl0dGVkIjpbIkNBUF9BVURJVF9XUklURSIsIkNBUF9DSE9XTiIsIkNBUF9EQUNfT1ZFUlJJREUiLCJDQVBfRk9XTkVSIiwiQ0FQX0ZTRVRJRCIsIkNBUF9LSUxMIiwiQ0FQX01LTk9EIiwiQ0FQX05FVF9CSU5EX1NFUlZJQ0UiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRGQ0FQIiwiQ0FQX1NFVEdJRCIsIkNBUF9TRVRQQ0FQIiwiQ0FQX1NFVFVJRCIsIkNBUF9TWVNfQ0hST09UIl19LCJjb21tYW5kIjpbIi9iaW4vc2giLCItYyIsIm5vZGUgL3Vzci9zcmMvYXBwL2luZGV4LmpzIl0sImVudl9ydWxlcyI6W3sicGF0dGVybiI6IlBBVEg9L3Vzci9sb2NhbC9zYmluOi91c3IvbG9jYWwvYmluOi91c3Ivc2JpbjovdXNyL2Jpbjovc2JpbjovYmluIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InN0cmluZyJ9XSwiZXhlY19wcm9jZXNzZXMiOltdLCJpZCI6Im1jci5taWNyb3NvZnQuY29tL2F6dXJlZG9jcy9hY2ktaGVsbG93b3JsZCIsImxheWVycyI6WyJjODcwNjIxZDkyYTA1ZmE1MjMxYjgwMzIxOGJjMzMzYjI3YTNmZTVkNGExOTRhNTBiOGE5M2M5MWU4YWUyNTI2IiwiNDA5NjZiODFmZTk3OGIxMzM3NjgxMzIxYTBlZGNiOTZlZjZmYzQ5ODFiMTFmNThmNDM1MmE4YTNjMDdhNzUwYiIsImUxMGJjZTVlMjI3NTE2N2EyOGJkNDA4ZjUxYWNmMTljMTNhOTIyZTllMjA1MjBkZDgwOTA5NDM2ZDMzMGM1MWQiLCJmNDUzNDRiOWRjMDgxYTRkNjE4OTg2ZjRhYTM0ZjIyMTBlZTFlMTIxNTdkNjk2NTM5OTRkZGY2NjQ5MmQ4NTUwIiwiOTRmNDRmMjc1YjllMzkyYjc5ODRjMzU2MWQyZDM2ZGJlZGM5Nzk2ZDg3YzY0OGEwZWM1NGM4NDM2YmNmZTIyNSIsIjZlYmJmNzE2MTFkYzIxMWRjNWYyMjEyNDEzMjEwY2E1NGExMGQ0NGU1NTcyMGRmNTBmYjZjOTFmNzM5NDM0MmEiLCI4YjQ4NDJmMDY5ODI4MTc1MzRhNzViY2Y3MTg2NTIxM2IwOWRmYTgzMTMyMjljMzg0ZTUyMDFkYWRiZDc1ZTI1IiwiODlhODVjNTQ1YTk3ZjMyMmI1MjhmNGJmOWExMTlhMjkxMDdhMThlM2U0NDQ1OTdkYjUzODQ1Yzg4NjQyYjgyZSJdLCJtb3VudHMiOlt7ImRlc3RpbmF0aW9uIjoiL2V0Yy9yZXNvbHYuY29uZiIsIm9wdGlvbnMiOlsicmJpbmQiLCJyc2hhcmVkIiwicnciXSwic291cmNlIjoic2FuZGJveDovLy90bXAvYXRsYXMvcmVzb2x2Y29uZi8uKyIsInR5cGUiOiJiaW5kIn1dLCJuYW1lIjoibWNyLm1pY3Jvc29mdC5jb20vYXp1cmVkb2NzL2FjaS1oZWxsb3dvcmxkIiwibm9fbmV3X3ByaXZpbGVnZXMiOmZhbHNlLCJzZWNjb21wX3Byb2ZpbGVfc2hhMjU2IjoiIiwic2lnbmFscyI6W10sInVzZXIiOnsiZ3JvdXBfaWRuYW1lcyI6W3sicGF0dGVybiI6IiIsInN0cmF0ZWd5IjoiYW55In1dLCJ1bWFzayI6IjAwMjIiLCJ1c2VyX2lkbmFtZSI6eyJwYXR0ZXJuIjoiIiwic3RyYXRlZ3kiOiJhbnkifX0sIndvcmtpbmdfZGlyIjoiL3Vzci9zcmMvYXBwIn1dCgphbGxvd19wcm9wZXJ0aWVzX2FjY2VzcyA6PSB0cnVlCmFsbG93X2R1bXBfc3RhY2tzIDo9IGZhbHNlCmFsbG93X3J1bnRpbWVfbG9nZ2luZyA6PSBmYWxzZQphbGxvd19lbnZpcm9ubWVudF92YXJpYWJsZV9kcm9wcGluZyA6PSB0cnVlCmFsbG93X3VuZW5jcnlwdGVkX3NjcmF0Y2ggOj0gZmFsc2UKYWxsb3dfY2FwYWJpbGl0eV9kcm9wcGluZyA6PSB0cnVlCgptb3VudF9kZXZpY2UgOj0gZGF0YS5mcmFtZXdvcmsubW91bnRfZGV2aWNlCnVubW91bnRfZGV2aWNlIDo9IGRhdGEuZnJhbWV3b3JrLnVubW91bnRfZGV2aWNlCm1vdW50X292ZXJsYXkgOj0gZGF0YS5mcmFtZXdvcmsubW91bnRfb3ZlcmxheQp1bm1vdW50X292ZXJsYXkgOj0gZGF0YS5mcmFtZXdvcmsudW5tb3VudF9vdmVybGF5CmNyZWF0ZV9jb250YWluZXIgOj0gZGF0YS5mcmFtZXdvcmsuY3JlYXRlX2NvbnRhaW5lcgpleGVjX2luX2NvbnRhaW5lciA6PSBkYXRhLmZyYW1ld29yay5leGVjX2luX2NvbnRhaW5lcgpleGVjX2V4dGVybmFsIDo9IGRhdGEuZnJhbWV3b3JrLmV4ZWNfZXh0ZXJuYWwKc2h1dGRvd25fY29udGFpbmVyIDo9IGRhdGEuZnJhbWV3b3JrLnNodXRkb3duX2NvbnRhaW5lcgpzaWduYWxfY29udGFpbmVyX3Byb2Nlc3MgOj0gZGF0YS5mcmFtZXdvcmsuc2lnbmFsX2NvbnRhaW5lcl9wcm9jZXNzCnBsYW45X21vdW50IDo9IGRhdGEuZnJhbWV3b3JrLnBsYW45X21vdW50CnBsYW45X3VubW91bnQgOj0gZGF0YS5mcmFtZXdvcmsucGxhbjlfdW5tb3VudApnZXRfcHJvcGVydGllcyA6PSBkYXRhLmZyYW1ld29yay5nZXRfcHJvcGVydGllcwpkdW1wX3N0YWNrcyA6PSBkYXRhLmZyYW1ld29yay5kdW1wX3N0YWNrcwpydW50aW1lX2xvZ2dpbmcgOj0gZGF0YS5mcmFtZXdvcmsucnVudGltZV9sb2dnaW5nCmxvYWRfZnJhZ21lbnQgOj0gZGF0YS5mcmFtZXdvcmsubG9hZF9mcmFnbWVudApzY3JhdGNoX21vdW50IDo9IGRhdGEuZnJhbWV3b3JrLnNjcmF0Y2hfbW91bnQKc2NyYXRjaF91bm1vdW50IDo9IGRhdGEuZnJhbWV3b3JrLnNjcmF0Y2hfdW5tb3VudAoKcmVhc29uIDo9IHsiZXJyb3JzIjogZGF0YS5mcmFtZXdvcmsuZXJyb3JzfQ=='
    }
    containers: [
      {
        name: 'aci-helloworld'
        properties: {
          image: context.resource.properties.containers.demo.image
          ports: [
            {
              protocol: context.resource.properties.containers.demo.ports.?http.?protocol ?? 'TCP'
              port: context.resource.properties.containers.demo.ports.?http.?containerPort ?? 80
            }
          ]
          resources: {
            requests: {
              memoryInGB: context.resource.properties.containers.demo.?resources.?requests.?memoryInMib != null ? context.resource.properties.containers.demo.?resources.?requests.?memoryInMib /1024 : json('1.0')
              cpu: context.resource.properties.containers.demo.?resources.?requests.?cpu ?? json('1.0')
            }
          }
        }
      }
    ]
    restartPolicy: 'Always'
    ipAddress: {
      ports: [
        {
          protocol: 'TCP'
          port: context.resource.properties.containers.demo.ports.?http.?containerPort ?? 80
        }
      ]
      type: 'Public'
    }
    osType: 'Linux'
  }
}

// NGroups for Confidential Computing
resource nGroups 'Microsoft.ContainerInstance/NGroups@2024-09-01-preview' = {
  name: nGroupsName
  location: resourceGroup().location
  properties: {
    elasticProfile: {
      desiredCount: context.resource.?properties.?replicas ?? desiredCount
      containerGroupNamingPolicy: {
        guidNamingPolicy: {
          prefix: prefixCG
        }
      }
    }
    containerGroupProfiles: [
      {
        resource: {
          id: '${resourcePrefix}Microsoft.ContainerInstance/containerGroupProfiles/${cgProfileName}'
        }
      }
    ]
  }
  tags: {
    cirrusTestScenario: 'confidential-1.basic'
  }
  dependsOn: [
    containerGroupProfile
  ]
}

// Outputs
output containerGroupProfileId string = containerGroupProfile.id
output nGroupId string = nGroups.id

output result object = {
  values: {
    containerGroupProfileId: containerGroupProfile.id
    nGroupsId: nGroups.id
    location: resourceGroup().location
    desiredCount: context.resource.?properties.?replicas ?? desiredCount
  }
}
