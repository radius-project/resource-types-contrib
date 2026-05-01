extension radius
extension radiusResources
extension persistentVolumes
extension secrets

param environment string

// Secure parameters with test defaults 
#disable-next-line secure-parameter-default @secure()
param username string = 'admin'
#disable-next-line secure-parameter-default @secure()
param password string = 'c2VjcmV0cGFzc3dvcmQ='
#disable-next-line secure-parameter-default @secure()
param apiKey string = 'abc123xyz'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'containers-testapp'
  properties: {
    environment: environment
  }
}

// Create a container that mounts the persistent volume
resource myContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'myapp'
  properties: {
    environment: environment
    application: app.id
    connections: {
      data: {
        source: myPersistentVolume.id
        disableDefaultEnvVars: false
      }
      secrets: {
        source: secret.id
        disableDefaultEnvVars: false
      }
    }
    containers: {
      web: {
        image: 'nginx:alpine'
        command: ['/bin/sh', '-c']
        args: ['nginx -g "daemon off;"']
        workingDir: '/usr/share/nginx/html'
        ports: {
          http: {
            containerPort: 80
            protocol: 'TCP'
          }
        }
        env: {
          CONNECTIONS_SECRET_USERNAME: {
            valueFrom: {
              secretKeyRef: {
                secretName: secret.name
                key: 'username'
              }
            }
          }
          CONNECTIONS_SECRET_APIKEY: {
            valueFrom: {
              secretKeyRef: {
                secretName: secret.name
                key: 'apikey'
              }
            }
          }
          CONNECTIONS_SECRET_PASSWORD: {
            valueFrom: {
              secretKeyRef: {
                secretName: secret.name
                key: 'password'
              }
            }
          }
        }
        volumeMounts: [
          {
            volumeName: 'data'
            mountPath: '/app/data'
          }
          {
            volumeName: 'cache'
            mountPath: '/tmp/cache'
          }
          {
            volumeName: 'secrets'
            mountPath: '/etc/secrets'
          }
        ] 
        resources: {
          requests: {
            cpu: '0.1'       
            memoryInMib: 2048   
          }
          limits: {
            cpu: '0.5'
            memoryInMib: 2048
          }
        }
        livenessProbe: {
          httpGet: {
            path: '/'
            port: 80
            scheme: 'http'
          }
          initialDelaySeconds: 10
          periodSeconds: 30
          timeoutSeconds: 5
          failureThreshold: 3
          successThreshold: 1
        }
        readinessProbe: {
          httpGet: {
            path: '/'
            port: 80
          }
          initialDelaySeconds: 5
          periodSeconds: 10
        }
      }
      init: {
        initContainer: true
        image: 'busybox:latest'
        command: ['sh', '-c']
        args: ['echo "Initializing..." && sleep 5']
        workingDir: '/tmp'
        env: {
          INIT_MESSAGE: {
            value: 'Starting initialization'
          }
        }
        resources: {
          requests: {
            cpu: '0.1'
            memoryInMib: 1024
          }
        }
      }
    }
    restartPolicy: 'Always'
    volumes: {
      data: {
        persistentVolume: {
          resourceId: myPersistentVolume.id
          accessMode: 'ReadWriteOnce'
        }
      }
      cache: {
        emptyDir: {
          medium: 'memory'
        }
      }
      secrets: {
        secretName: secret.name
      }
    }
    extensions: {
      daprSidecar: {
        appId: 'myapp'
        appPort: 80
      }
    }
    platformOptions: {
      sku: 'Confidential'
      ccePolicy: 'cGFja2FnZSBwb2xpY3kKCmltcG9ydCBmdXR1cmUua2V5d29yZHMuZXZlcnkKaW1wb3J0IGZ1dHVyZS5rZXl3b3Jkcy5pbgoKYXBpX3ZlcnNpb24gOj0gIjAuMTAuMCIKZnJhbWV3b3JrX3ZlcnNpb24gOj0gIjAuMi4zIgoKZnJhZ21lbnRzIDo9IFsKICB7CiAgICAiZmVlZCI6ICJtY3IubWljcm9zb2Z0LmNvbS9hY2kvYWNpLWNjLWluZnJhLWZyYWdtZW50IiwKICAgICJpbmNsdWRlcyI6IFsKICAgICAgImNvbnRhaW5lcnMiLAogICAgICAiZnJhZ21lbnRzIgogICAgXSwKICAgICJpc3N1ZXIiOiAiZGlkOng1MDk6MDpzaGEyNTY6SV9faXVMMjVvWEVWRmRUUF9hQkx4X2VUMVJQSGJDUV9FQ0JRZllacHQ5czo6ZWt1OjEuMy42LjEuNC4xLjMxMS43Ni41OS4xLjMiLAogICAgIm1pbmltdW1fc3ZuIjogIjQiCiAgfQpdCgpjb250YWluZXJzIDo9IFt7ImFsbG93X2VsZXZhdGVkIjpmYWxzZSwiYWxsb3dfc3RkaW9fYWNjZXNzIjp0cnVlLCJjYXBhYmlsaXRpZXMiOnsiYW1iaWVudCI6W10sImJvdW5kaW5nIjpbIkNBUF9DSE9XTiIsIkNBUF9EQUNfT1ZFUlJJREUiLCJDQVBfRlNFVElEIiwiQ0FQX0ZPV05FUiIsIkNBUF9NS05PRCIsIkNBUF9ORVRfUkFXIiwiQ0FQX1NFVEdJRCIsIkNBUF9TRVRVSUQiLCJDQVBfU0VURkNBUCIsIkNBUF9TRVRQQ0FQIiwiQ0FQX05FVF9CSU5EX1NFUlZJQ0UiLCJDQVBfU1lTX0NIUk9PVCIsIkNBUF9LSUxMIiwiQ0FQX0FVRElUX1dSSVRFIl0sImVmZmVjdGl2ZSI6WyJDQVBfQ0hPV04iLCJDQVBfREFDX09WRVJSSURFIiwiQ0FQX0ZTRVRJRCIsIkNBUF9GT1dORVIiLCJDQVBfTUtOT0QiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRHSUQiLCJDQVBfU0VUVUlEIiwiQ0FQX1NFVEZDQVAiLCJDQVBfU0VUUENBUCIsIkNBUF9ORVRfQklORF9TRVJWSUNFIiwiQ0FQX1NZU19DSFJPT1QiLCJDQVBfS0lMTCIsIkNBUF9BVURJVF9XUklURSJdLCJpbmhlcml0YWJsZSI6W10sInBlcm1pdHRlZCI6WyJDQVBfQ0hPV04iLCJDQVBfREFDX09WRVJSSURFIiwiQ0FQX0ZTRVRJRCIsIkNBUF9GT1dORVIiLCJDQVBfTUtOT0QiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRHSUQiLCJDQVBfU0VUVUlEIiwiQ0FQX1NFVEZDQVAiLCJDQVBfU0VUUENBUCIsIkNBUF9ORVRfQklORF9TRVJWSUNFIiwiQ0FQX1NZU19DSFJPT1QiLCJDQVBfS0lMTCIsIkNBUF9BVURJVF9XUklURSJdfSwiY29tbWFuZCI6WyIvcGF1c2UiXSwiZW52X3J1bGVzIjpbeyJwYXR0ZXJuIjoiUEFUSD0vdXNyL2xvY2FsL3NiaW46L3Vzci9sb2NhbC9iaW46L3Vzci9zYmluOi91c3IvYmluOi9zYmluOi9iaW4iLCJyZXF1aXJlZCI6dHJ1ZSwic3RyYXRlZ3kiOiJzdHJpbmcifSx7InBhdHRlcm4iOiJURVJNPXh0ZXJtIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InN0cmluZyJ9XSwiZXhlY19wcm9jZXNzZXMiOltdLCJsYXllcnMiOlsiMTZiNTE0MDU3YTA2YWQ2NjVmOTJjMDI4NjNhY2EwNzRmZDU5NzZjNzU1ZDI2YmZmMTYzNjUyOTkxNjllODQxNSJdLCJtb3VudHMiOltdLCJuYW1lIjoicGF1c2UtY29udGFpbmVyIiwibm9fbmV3X3ByaXZpbGVnZXMiOmZhbHNlLCJzZWNjb21wX3Byb2ZpbGVfc2hhMjU2IjoiIiwic2lnbmFscyI6W10sInVzZXIiOnsiZ3JvdXBfaWRuYW1lcyI6W3sicGF0dGVybiI6IiIsInN0cmF0ZWd5IjoiYW55In1dLCJ1bWFzayI6IjAwMjIiLCJ1c2VyX2lkbmFtZSI6eyJwYXR0ZXJuIjoiIiwic3RyYXRlZ3kiOiJhbnkifX0sIndvcmtpbmdfZGlyIjoiLyJ9LHsiYWxsb3dfZWxldmF0ZWQiOmZhbHNlLCJhbGxvd19zdGRpb19hY2Nlc3MiOnRydWUsImNhcGFiaWxpdGllcyI6eyJhbWJpZW50IjpbXSwiYm91bmRpbmciOlsiQ0FQX0FVRElUX1dSSVRFIiwiQ0FQX0NIT1dOIiwiQ0FQX0RBQ19PVkVSUklERSIsIkNBUF9GT1dORVIiLCJDQVBfRlNFVElEIiwiQ0FQX0tJTEwiLCJDQVBfTUtOT0QiLCJDQVBfTkVUX0JJTkRfU0VSVklDRSIsIkNBUF9ORVRfUkFXIiwiQ0FQX1NFVEZDQVAiLCJDQVBfU0VUR0lEIiwiQ0FQX1NFVFBDQVAiLCJDQVBfU0VUVUlEIiwiQ0FQX1NZU19DSFJPT1QiXSwiZWZmZWN0aXZlIjpbIkNBUF9BVURJVF9XUklURSIsIkNBUF9DSE9XTiIsIkNBUF9EQUNfT1ZFUlJJREUiLCJDQVBfRk9XTkVSIiwiQ0FQX0ZTRVRJRCIsIkNBUF9LSUxMIiwiQ0FQX01LTk9EIiwiQ0FQX05FVF9CSU5EX1NFUlZJQ0UiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRGQ0FQIiwiQ0FQX1NFVEdJRCIsIkNBUF9TRVRQQ0FQIiwiQ0FQX1NFVFVJRCIsIkNBUF9TWVNfQ0hST09UIl0sImluaGVyaXRhYmxlIjpbXSwicGVybWl0dGVkIjpbIkNBUF9BVURJVF9XUklURSIsIkNBUF9DSE9XTiIsIkNBUF9EQUNfT1ZFUlJJREUiLCJDQVBfRk9XTkVSIiwiQ0FQX0ZTRVRJRCIsIkNBUF9LSUxMIiwiQ0FQX01LTk9EIiwiQ0FQX05FVF9CSU5EX1NFUlZJQ0UiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRGQ0FQIiwiQ0FQX1NFVEdJRCIsIkNBUF9TRVRQQ0FQIiwiQ0FQX1NFVFVJRCIsIkNBUF9TWVNfQ0hST09UIl19LCJjb21tYW5kIjpbIi9iaW4vc2giLCItYyIsIm5naW54IC1nIFwiZGFlbW9uIG9mZjtcIiJdLCJlbnZfcnVsZXMiOlt7InBhdHRlcm4iOiJBQ01FX1ZFUlNJT049MC4zLjEiLCJyZXF1aXJlZCI6ZmFsc2UsInN0cmF0ZWd5Ijoic3RyaW5nIn0seyJwYXR0ZXJuIjoiQ09OTkVDVElPTlNfREFUQV8uKz0uKyIsInJlcXVpcmVkIjp0cnVlLCJzdHJhdGVneSI6InJlMiJ9LHsicGF0dGVybiI6IkNPTk5FQ1RJT05TX1NFQ1JFVFNfLis9LisiLCJyZXF1aXJlZCI6dHJ1ZSwic3RyYXRlZ3kiOiJyZTIifSx7InBhdHRlcm4iOiJDT05ORUNUSU9OU19TRUNSRVRfQVBJS0VZPS4rIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InJlMiJ9LHsicGF0dGVybiI6IkNPTk5FQ1RJT05TX1NFQ1JFVF9QQVNTV09SRD0uKyIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJyZTIifSx7InBhdHRlcm4iOiJDT05ORUNUSU9OU19TRUNSRVRfVVNFUk5BTUU9LisiLCJyZXF1aXJlZCI6ZmFsc2UsInN0cmF0ZWd5IjoicmUyIn0seyJwYXR0ZXJuIjoiRFlOUEtHX1JFTEVBU0U9MSIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJzdHJpbmcifSx7InBhdHRlcm4iOiJOR0lOWF9WRVJTSU9OPTEuMjkuOCIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJzdHJpbmcifSx7InBhdHRlcm4iOiJOSlNfUkVMRUFTRT0xIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InN0cmluZyJ9LHsicGF0dGVybiI6Ik5KU19WRVJTSU9OPTAuOS42IiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InN0cmluZyJ9LHsicGF0dGVybiI6IlBBVEg9L3Vzci9sb2NhbC9zYmluOi91c3IvbG9jYWwvYmluOi91c3Ivc2JpbjovdXNyL2Jpbjovc2JpbjovYmluIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InN0cmluZyJ9LHsicGF0dGVybiI6IlBLR19SRUxFQVNFPTEiLCJyZXF1aXJlZCI6ZmFsc2UsInN0cmF0ZWd5Ijoic3RyaW5nIn1dLCJleGVjX3Byb2Nlc3NlcyI6W10sImlkIjoibmdpbng6YWxwaW5lIiwibGF5ZXJzIjpbIjBiNWQ2MDQ1ODU0NjA3MmMyYmJkZDEwZTRmNzk0NTI2OTgwNGFkOGI5ZjM4NjgxYTQ1M2M3MDk1YmM1ZTFmMTYiLCI1YTc2NWUwOTg5MDI1ODg3MDE0YzgwNjhlYjNhMjIzOWI2ZDJiMDMzNDZlMjQwZjVkNDg4OGI0YjM5NmViZjY4IiwiY2YwY2RlZDhjNDI1Nzc2MmIwM2MzNmI5YjJlYzdjNmU2NTdjNmQxZmMzZWRmM2EzMzEyNWMwYzA0YjRkNWU2YyIsIjM1MjE0ZjBmZWI5OTRiODY3MmRmYjg3MjcyMzY5OTg3YzYzZWM4N2ZjODExYWIzNDcwYWFkMTdlODViZTk5OWEiLCJkZmQ4OTRhZjg5NWMyY2YzZmRlODYzMzlhMWU5ZTg4ZTY2ZWI4ZWIwOTdkNjQyNzk5ODA2NzM2N2EyZDA4NWY3IiwiNDhlODhmOWZiYzQ4YjFlZTJjY2MwMjBmMTFjNmZlNTE2NTgyNjY1NzA4MGM4M2E0NzE0Y2UzZThkMmIxNDczZCIsIjA3Mjc2YjkzYmU1OWJhM2VmZmRiZjFhNjVkOTYyZDRlN2Q0YWFmM2E2NTE3NmZlMTJjNjZhYTc1NGI5YWVlNjIiLCI3NTc4ZGQ5ODEyNjk4OTM5YjUyNmVkODZhYWFmZjFjZjM3YWNiY2JiZDc1MjQ3ZjYwZjM4NDViOWE5MWZkMGM1Il0sIm1vdW50cyI6W3siZGVzdGluYXRpb24iOiIvYXBwL2RhdGEiLCJvcHRpb25zIjpbInJiaW5kIiwicnNoYXJlZCJdLCJzb3VyY2UiOiJbcmVzb3VyY2VJZCgnUmFkaXVzLkNvbXB1dGUvcGVyc2lzdGVudFZvbHVtZXMnLCAnbXlwZXJzaXN0ZW50dm9sdW1lJyldIiwidHlwZSI6ImJpbmQifSx7ImRlc3RpbmF0aW9uIjoiL2V0Yy9yZXNvbHYuY29uZiIsIm9wdGlvbnMiOlsicmJpbmQiLCJyc2hhcmVkIiwicnciXSwic291cmNlIjoic2FuZGJveDovLy90bXAvYXRsYXMvcmVzb2x2Y29uZi8uKyIsInR5cGUiOiJiaW5kIn0seyJkZXN0aW5hdGlvbiI6Ii9ldGMvc2VjcmV0cyIsIm9wdGlvbnMiOlsicmJpbmQiLCJybyIsInJzaGFyZWQiXSwic291cmNlIjoiW2Zvcm1hdCgnYXBwLXNlY3JldHMtezB9JywgdW5pcXVlU3RyaW5nKGRlcGxveW1lbnQoKS5uYW1lKSldIiwidHlwZSI6ImJpbmQifSx7ImRlc3RpbmF0aW9uIjoiL3RtcC9jYWNoZSIsIm9wdGlvbnMiOlsicmJpbmQiLCJyc2hhcmVkIl0sInNvdXJjZSI6ImVwaGVtZXJhbDovL2NhY2hlIiwidHlwZSI6ImJpbmQifV0sIm5hbWUiOiJuZ2lueDphbHBpbmUiLCJub19uZXdfcHJpdmlsZWdlcyI6ZmFsc2UsInNlY2NvbXBfcHJvZmlsZV9zaGEyNTYiOiIiLCJzaWduYWxzIjpbM10sInVzZXIiOnsiZ3JvdXBfaWRuYW1lcyI6W3sicGF0dGVybiI6IiIsInN0cmF0ZWd5IjoiYW55In1dLCJ1bWFzayI6IjAwMjIiLCJ1c2VyX2lkbmFtZSI6eyJwYXR0ZXJuIjoiIiwic3RyYXRlZ3kiOiJhbnkifX0sIndvcmtpbmdfZGlyIjoiL3Vzci9zaGFyZS9uZ2lueC9odG1sIn1dCgphbGxvd19wcm9wZXJ0aWVzX2FjY2VzcyA6PSB0cnVlCmFsbG93X2R1bXBfc3RhY2tzIDo9IGZhbHNlCmFsbG93X3J1bnRpbWVfbG9nZ2luZyA6PSBmYWxzZQphbGxvd19lbnZpcm9ubWVudF92YXJpYWJsZV9kcm9wcGluZyA6PSB0cnVlCmFsbG93X3VuZW5jcnlwdGVkX3NjcmF0Y2ggOj0gZmFsc2UKYWxsb3dfY2FwYWJpbGl0eV9kcm9wcGluZyA6PSB0cnVlCgptb3VudF9kZXZpY2UgOj0gZGF0YS5mcmFtZXdvcmsubW91bnRfZGV2aWNlCnVubW91bnRfZGV2aWNlIDo9IGRhdGEuZnJhbWV3b3JrLnVubW91bnRfZGV2aWNlCm1vdW50X292ZXJsYXkgOj0gZGF0YS5mcmFtZXdvcmsubW91bnRfb3ZlcmxheQp1bm1vdW50X292ZXJsYXkgOj0gZGF0YS5mcmFtZXdvcmsudW5tb3VudF9vdmVybGF5CmNyZWF0ZV9jb250YWluZXIgOj0gZGF0YS5mcmFtZXdvcmsuY3JlYXRlX2NvbnRhaW5lcgpleGVjX2luX2NvbnRhaW5lciA6PSBkYXRhLmZyYW1ld29yay5leGVjX2luX2NvbnRhaW5lcgpleGVjX2V4dGVybmFsIDo9IGRhdGEuZnJhbWV3b3JrLmV4ZWNfZXh0ZXJuYWwKc2h1dGRvd25fY29udGFpbmVyIDo9IGRhdGEuZnJhbWV3b3JrLnNodXRkb3duX2NvbnRhaW5lcgpzaWduYWxfY29udGFpbmVyX3Byb2Nlc3MgOj0gZGF0YS5mcmFtZXdvcmsuc2lnbmFsX2NvbnRhaW5lcl9wcm9jZXNzCnBsYW45X21vdW50IDo9IGRhdGEuZnJhbWV3b3JrLnBsYW45X21vdW50CnBsYW45X3VubW91bnQgOj0gZGF0YS5mcmFtZXdvcmsucGxhbjlfdW5tb3VudApnZXRfcHJvcGVydGllcyA6PSBkYXRhLmZyYW1ld29yay5nZXRfcHJvcGVydGllcwpkdW1wX3N0YWNrcyA6PSBkYXRhLmZyYW1ld29yay5kdW1wX3N0YWNrcwpydW50aW1lX2xvZ2dpbmcgOj0gZGF0YS5mcmFtZXdvcmsucnVudGltZV9sb2dnaW5nCmxvYWRfZnJhZ21lbnQgOj0gZGF0YS5mcmFtZXdvcmsubG9hZF9mcmFnbWVudApzY3JhdGNoX21vdW50IDo9IGRhdGEuZnJhbWV3b3JrLnNjcmF0Y2hfbW91bnQKc2NyYXRjaF91bm1vdW50IDo9IGRhdGEuZnJhbWV3b3JrLnNjcmF0Y2hfdW5tb3VudAoKcmVhc29uIDo9IHsiZXJyb3JzIjogZGF0YS5mcmFtZXdvcmsuZXJyb3JzfQ=='
    }
    replicas: 1
    autoScaling: {
      maxReplicas: 3
      metrics: [
        {
          kind: 'cpu'
          target: {
            averageUtilization: 50
          }
        }
      ]
    }
  }
}

resource myPersistentVolume 'Radius.Compute/persistentVolumes@2025-08-01-preview' = {
  name: 'mypersistentvolume'
  properties: {
    environment: environment
    application: app.id
    sizeInGib: 1
  }
}

resource secret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'app-secrets-${uniqueString(deployment().name)}'
  properties: {
    environment: environment
    application: app.id
    data: {
      username: {
        value: username
      }
      password: {
        value: password
        encoding: 'base64'
      }
      apikey: {
        value: apiKey
      }
    }
  }
}
