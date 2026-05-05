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

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'containers-testapp8'
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
      confidentialComputeProperties: {
        ccePolicy: 'cGFja2FnZSBwb2xpY3kKCmltcG9ydCBmdXR1cmUua2V5d29yZHMuZXZlcnkKaW1wb3J0IGZ1dHVyZS5rZXl3b3Jkcy5pbgoKYXBpX3ZlcnNpb24gOj0gIjAuMTAuMCIKZnJhbWV3b3JrX3ZlcnNpb24gOj0gIjAuMi4zIgoKZnJhZ21lbnRzIDo9IFsKICB7CiAgICAiZmVlZCI6ICJtY3IubWljcm9zb2Z0LmNvbS9hY2kvYWNpLWNjLWluZnJhLWZyYWdtZW50IiwKICAgICJpbmNsdWRlcyI6IFsKICAgICAgImNvbnRhaW5lcnMiLAogICAgICAiZnJhZ21lbnRzIgogICAgXSwKICAgICJpc3N1ZXIiOiAiZGlkOng1MDk6MDpzaGEyNTY6SV9faXVMMjVvWEVWRmRUUF9hQkx4X2VUMVJQSGJDUV9FQ0JRZllacHQ5czo6ZWt1OjEuMy42LjEuNC4xLjMxMS43Ni41OS4xLjMiLAogICAgIm1pbmltdW1fc3ZuIjogIjQiCiAgfQpdCgpjb250YWluZXJzIDo9IFt7ImFsbG93X2VsZXZhdGVkIjpmYWxzZSwiYWxsb3dfc3RkaW9fYWNjZXNzIjp0cnVlLCJjYXBhYmlsaXRpZXMiOnsiYW1iaWVudCI6W10sImJvdW5kaW5nIjpbIkNBUF9DSE9XTiIsIkNBUF9EQUNfT1ZFUlJJREUiLCJDQVBfRlNFVElEIiwiQ0FQX0ZPV05FUiIsIkNBUF9NS05PRCIsIkNBUF9ORVRfUkFXIiwiQ0FQX1NFVEdJRCIsIkNBUF9TRVRVSUQiLCJDQVBfU0VURkNBUCIsIkNBUF9TRVRQQ0FQIiwiQ0FQX05FVF9CSU5EX1NFUlZJQ0UiLCJDQVBfU1lTX0NIUk9PVCIsIkNBUF9LSUxMIiwiQ0FQX0FVRElUX1dSSVRFIl0sImVmZmVjdGl2ZSI6WyJDQVBfQ0hPV04iLCJDQVBfREFDX09WRVJSSURFIiwiQ0FQX0ZTRVRJRCIsIkNBUF9GT1dORVIiLCJDQVBfTUtOT0QiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRHSUQiLCJDQVBfU0VUVUlEIiwiQ0FQX1NFVEZDQVAiLCJDQVBfU0VUUENBUCIsIkNBUF9ORVRfQklORF9TRVJWSUNFIiwiQ0FQX1NZU19DSFJPT1QiLCJDQVBfS0lMTCIsIkNBUF9BVURJVF9XUklURSJdLCJpbmhlcml0YWJsZSI6W10sInBlcm1pdHRlZCI6WyJDQVBfQ0hPV04iLCJDQVBfREFDX09WRVJSSURFIiwiQ0FQX0ZTRVRJRCIsIkNBUF9GT1dORVIiLCJDQVBfTUtOT0QiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRHSUQiLCJDQVBfU0VUVUlEIiwiQ0FQX1NFVEZDQVAiLCJDQVBfU0VUUENBUCIsIkNBUF9ORVRfQklORF9TRVJWSUNFIiwiQ0FQX1NZU19DSFJPT1QiLCJDQVBfS0lMTCIsIkNBUF9BVURJVF9XUklURSJdfSwiY29tbWFuZCI6WyIvcGF1c2UiXSwiZW52X3J1bGVzIjpbeyJwYXR0ZXJuIjoiUEFUSD0vdXNyL2xvY2FsL3NiaW46L3Vzci9sb2NhbC9iaW46L3Vzci9zYmluOi91c3IvYmluOi9zYmluOi9iaW4iLCJyZXF1aXJlZCI6dHJ1ZSwic3RyYXRlZ3kiOiJzdHJpbmcifSx7InBhdHRlcm4iOiJURVJNPXh0ZXJtIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InN0cmluZyJ9XSwiZXhlY19wcm9jZXNzZXMiOltdLCJsYXllcnMiOlsiMTZiNTE0MDU3YTA2YWQ2NjVmOTJjMDI4NjNhY2EwNzRmZDU5NzZjNzU1ZDI2YmZmMTYzNjUyOTkxNjllODQxNSJdLCJtb3VudHMiOltdLCJuYW1lIjoicGF1c2UtY29udGFpbmVyIiwibm9fbmV3X3ByaXZpbGVnZXMiOmZhbHNlLCJzZWNjb21wX3Byb2ZpbGVfc2hhMjU2IjoiIiwic2lnbmFscyI6W10sInVzZXIiOnsiZ3JvdXBfaWRuYW1lcyI6W3sicGF0dGVybiI6IiIsInN0cmF0ZWd5IjoiYW55In1dLCJ1bWFzayI6IjAwMjIiLCJ1c2VyX2lkbmFtZSI6eyJwYXR0ZXJuIjoiIiwic3RyYXRlZ3kiOiJhbnkifX0sIndvcmtpbmdfZGlyIjoiLyJ9LHsiYWxsb3dfZWxldmF0ZWQiOmZhbHNlLCJhbGxvd19zdGRpb19hY2Nlc3MiOnRydWUsImNhcGFiaWxpdGllcyI6eyJhbWJpZW50IjpbXSwiYm91bmRpbmciOlsiQ0FQX0FVRElUX1dSSVRFIiwiQ0FQX0NIT1dOIiwiQ0FQX0RBQ19PVkVSUklERSIsIkNBUF9GT1dORVIiLCJDQVBfRlNFVElEIiwiQ0FQX0tJTEwiLCJDQVBfTUtOT0QiLCJDQVBfTkVUX0JJTkRfU0VSVklDRSIsIkNBUF9ORVRfUkFXIiwiQ0FQX1NFVEZDQVAiLCJDQVBfU0VUR0lEIiwiQ0FQX1NFVFBDQVAiLCJDQVBfU0VUVUlEIiwiQ0FQX1NZU19DSFJPT1QiXSwiZWZmZWN0aXZlIjpbIkNBUF9BVURJVF9XUklURSIsIkNBUF9DSE9XTiIsIkNBUF9EQUNfT1ZFUlJJREUiLCJDQVBfRk9XTkVSIiwiQ0FQX0ZTRVRJRCIsIkNBUF9LSUxMIiwiQ0FQX01LTk9EIiwiQ0FQX05FVF9CSU5EX1NFUlZJQ0UiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRGQ0FQIiwiQ0FQX1NFVEdJRCIsIkNBUF9TRVRQQ0FQIiwiQ0FQX1NFVFVJRCIsIkNBUF9TWVNfQ0hST09UIl0sImluaGVyaXRhYmxlIjpbXSwicGVybWl0dGVkIjpbIkNBUF9BVURJVF9XUklURSIsIkNBUF9DSE9XTiIsIkNBUF9EQUNfT1ZFUlJJREUiLCJDQVBfRk9XTkVSIiwiQ0FQX0ZTRVRJRCIsIkNBUF9LSUxMIiwiQ0FQX01LTk9EIiwiQ0FQX05FVF9CSU5EX1NFUlZJQ0UiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRGQ0FQIiwiQ0FQX1NFVEdJRCIsIkNBUF9TRVRQQ0FQIiwiQ0FQX1NFVFVJRCIsIkNBUF9TWVNfQ0hST09UIl19LCJjb21tYW5kIjpbIi9iaW4vc2giLCItYyIsIm5naW54IC1nIFwiZGFlbW9uIG9mZjtcIiJdLCJlbnZfcnVsZXMiOlt7InBhdHRlcm4iOiJBQ01FX1ZFUlNJT049MC4zLjEiLCJyZXF1aXJlZCI6ZmFsc2UsInN0cmF0ZWd5Ijoic3RyaW5nIn0seyJwYXR0ZXJuIjoiQ09OTkVDVElPTlNfREFUQV8uKz0uKyIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJyZTIifSx7InBhdHRlcm4iOiJDT05ORUNUSU9OU19TRUNSRVRTXy4rPS4rIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InJlMiJ9LHsicGF0dGVybiI6IkNPTk5FQ1RJT05TX1NFQ1JFVF9BUElLRVk9LisiLCJyZXF1aXJlZCI6ZmFsc2UsInN0cmF0ZWd5IjoicmUyIn0seyJwYXR0ZXJuIjoiQ09OTkVDVElPTlNfU0VDUkVUX1BBU1NXT1JEPS4rIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InJlMiJ9LHsicGF0dGVybiI6IkNPTk5FQ1RJT05TX1NFQ1JFVF9VU0VSTkFNRT0uKyIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJyZTIifSx7InBhdHRlcm4iOiJDT05ORUNUSU9OXy4rPS4rIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InJlMiJ9LHsicGF0dGVybiI6IkRZTlBLR19SRUxFQVNFPTEiLCJyZXF1aXJlZCI6ZmFsc2UsInN0cmF0ZWd5Ijoic3RyaW5nIn0seyJwYXR0ZXJuIjoiRmFicmljX0FwcGxpY2F0aW9uTmFtZT0uKyIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJyZTIifSx7InBhdHRlcm4iOiJGYWJyaWNfQ29kZVBhY2thZ2VOYW1lPS4rIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InJlMiJ9LHsicGF0dGVybiI6IkZhYnJpY19JZD0uKyIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJyZTIifSx7InBhdHRlcm4iOiJGYWJyaWNfTkVULis9LisiLCJyZXF1aXJlZCI6ZmFsc2UsInN0cmF0ZWd5IjoicmUyIn0seyJwYXR0ZXJuIjoiRmFicmljX05ldHdvcmtpbmdNb2RlPS4rIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InJlMiJ9LHsicGF0dGVybiI6IkZhYnJpY19Ob2RlSVBPckZRRE49LisiLCJyZXF1aXJlZCI6ZmFsc2UsInN0cmF0ZWd5IjoicmUyIn0seyJwYXR0ZXJuIjoiRmFicmljX1NlcnZpY2VEbnNOYW1lPS4rIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InJlMiJ9LHsicGF0dGVybiI6IkZhYnJpY19TZXJ2aWNlTmFtZT0uKyIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJyZTIifSx7InBhdHRlcm4iOiJIT1NUTkFNRT0uKyIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJyZTIifSx7InBhdHRlcm4iOiJOR0lOWF9WRVJTSU9OPTEuMjkuOCIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJzdHJpbmcifSx7InBhdHRlcm4iOiJOSlNfUkVMRUFTRT0xIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InN0cmluZyJ9LHsicGF0dGVybiI6Ik5KU19WRVJTSU9OPTAuOS42IiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InN0cmluZyJ9LHsicGF0dGVybiI6IlBBVEg9L3Vzci9sb2NhbC9zYmluOi91c3IvbG9jYWwvYmluOi91c3Ivc2JpbjovdXNyL2Jpbjovc2JpbjovYmluIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InN0cmluZyJ9LHsicGF0dGVybiI6IlBLR19SRUxFQVNFPTEiLCJyZXF1aXJlZCI6ZmFsc2UsInN0cmF0ZWd5Ijoic3RyaW5nIn0seyJwYXR0ZXJuIjoiVEVSTT14dGVybSIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJzdHJpbmcifV0sImV4ZWNfcHJvY2Vzc2VzIjpbXSwiaWQiOiJuZ2lueDphbHBpbmUiLCJsYXllcnMiOlsiMGI1ZDYwNDU4NTQ2MDcyYzJiYmRkMTBlNGY3OTQ1MjY5ODA0YWQ4YjlmMzg2ODFhNDUzYzcwOTViYzVlMWYxNiIsIjVhNzY1ZTA5ODkwMjU4ODcwMTRjODA2OGViM2EyMjM5YjZkMmIwMzM0NmUyNDBmNWQ0ODg4YjRiMzk2ZWJmNjgiLCJjZjBjZGVkOGM0MjU3NzYyYjAzYzM2YjliMmVjN2M2ZTY1N2M2ZDFmYzNlZGYzYTMzMTI1YzBjMDRiNGQ1ZTZjIiwiMzUyMTRmMGZlYjk5NGI4NjcyZGZiODcyNzIzNjk5ODdjNjNlYzg3ZmM4MTFhYjM0NzBhYWQxN2U4NWJlOTk5YSIsImRmZDg5NGFmODk1YzJjZjNmZGU4NjMzOWExZTllODhlNjZlYjhlYjA5N2Q2NDI3OTk4MDY3MzY3YTJkMDg1ZjciLCI0OGU4OGY5ZmJjNDhiMWVlMmNjYzAyMGYxMWM2ZmU1MTY1ODI2NjU3MDgwYzgzYTQ3MTRjZTNlOGQyYjE0NzNkIiwiMDcyNzZiOTNiZTU5YmEzZWZmZGJmMWE2NWQ5NjJkNGU3ZDRhYWYzYTY1MTc2ZmUxMmM2NmFhNzU0YjlhZWU2MiIsIjc1NzhkZDk4MTI2OTg5MzliNTI2ZWQ4NmFhYWZmMWNmMzdhY2JjYmJkNzUyNDdmNjBmMzg0NWI5YTkxZmQwYzUiXSwibW91bnRzIjpbeyJkZXN0aW5hdGlvbiI6Ii9hcHAvZGF0YSIsIm9wdGlvbnMiOlsicmJpbmQiLCJyc2hhcmVkIl0sInNvdXJjZSI6IltyZXNvdXJjZUlkKCdSYWRpdXMuQ29tcHV0ZS9wZXJzaXN0ZW50Vm9sdW1lcycsICdteXBlcnNpc3RlbnR2b2x1bWUnKV0iLCJ0eXBlIjoiYmluZCJ9LHsiZGVzdGluYXRpb24iOiIvZXRjL3Jlc29sdi5jb25mIiwib3B0aW9ucyI6WyJyYmluZCIsInJzaGFyZWQiLCJydyJdLCJzb3VyY2UiOiJzYW5kYm94Oi8vL3RtcC9hdGxhcy9yZXNvbHZjb25mLy4rIiwidHlwZSI6ImJpbmQifSx7ImRlc3RpbmF0aW9uIjoiL2V0Yy9zZWNyZXRzIiwib3B0aW9ucyI6WyJyYmluZCIsInJvIiwicnNoYXJlZCJdLCJzb3VyY2UiOiJbZm9ybWF0KCdhcHAtc2VjcmV0cy17MH0nLCB1bmlxdWVTdHJpbmcoZGVwbG95bWVudCgpLm5hbWUpKV0iLCJ0eXBlIjoiYmluZCJ9LHsiZGVzdGluYXRpb24iOiIvdG1wL2NhY2hlIiwib3B0aW9ucyI6WyJyYmluZCIsInJzaGFyZWQiXSwic291cmNlIjoiZXBoZW1lcmFsOi8vY2FjaGUiLCJ0eXBlIjoiYmluZCJ9XSwibmFtZSI6Im5naW54OmFscGluZSIsIm5vX25ld19wcml2aWxlZ2VzIjpmYWxzZSwic2VjY29tcF9wcm9maWxlX3NoYTI1NiI6IiIsInNpZ25hbHMiOlszXSwidXNlciI6eyJncm91cF9pZG5hbWVzIjpbeyJwYXR0ZXJuIjoiIiwic3RyYXRlZ3kiOiJhbnkifV0sInVtYXNrIjoiMDAyMiIsInVzZXJfaWRuYW1lIjp7InBhdHRlcm4iOiIiLCJzdHJhdGVneSI6ImFueSJ9fSwid29ya2luZ19kaXIiOiIvdXNyL3NoYXJlL25naW54L2h0bWwifSx7ImFsbG93X2VsZXZhdGVkIjpmYWxzZSwiYWxsb3dfc3RkaW9fYWNjZXNzIjp0cnVlLCJjYXBhYmlsaXRpZXMiOnsiYW1iaWVudCI6W10sImJvdW5kaW5nIjpbIkNBUF9BVURJVF9XUklURSIsIkNBUF9DSE9XTiIsIkNBUF9EQUNfT1ZFUlJJREUiLCJDQVBfRk9XTkVSIiwiQ0FQX0ZTRVRJRCIsIkNBUF9LSUxMIiwiQ0FQX01LTk9EIiwiQ0FQX05FVF9CSU5EX1NFUlZJQ0UiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRGQ0FQIiwiQ0FQX1NFVEdJRCIsIkNBUF9TRVRQQ0FQIiwiQ0FQX1NFVFVJRCIsIkNBUF9TWVNfQ0hST09UIl0sImVmZmVjdGl2ZSI6WyJDQVBfQVVESVRfV1JJVEUiLCJDQVBfQ0hPV04iLCJDQVBfREFDX09WRVJSSURFIiwiQ0FQX0ZPV05FUiIsIkNBUF9GU0VUSUQiLCJDQVBfS0lMTCIsIkNBUF9NS05PRCIsIkNBUF9ORVRfQklORF9TRVJWSUNFIiwiQ0FQX05FVF9SQVciLCJDQVBfU0VURkNBUCIsIkNBUF9TRVRHSUQiLCJDQVBfU0VUUENBUCIsIkNBUF9TRVRVSUQiLCJDQVBfU1lTX0NIUk9PVCJdLCJpbmhlcml0YWJsZSI6W10sInBlcm1pdHRlZCI6WyJDQVBfQVVESVRfV1JJVEUiLCJDQVBfQ0hPV04iLCJDQVBfREFDX09WRVJSSURFIiwiQ0FQX0ZPV05FUiIsIkNBUF9GU0VUSUQiLCJDQVBfS0lMTCIsIkNBUF9NS05PRCIsIkNBUF9ORVRfQklORF9TRVJWSUNFIiwiQ0FQX05FVF9SQVciLCJDQVBfU0VURkNBUCIsIkNBUF9TRVRHSUQiLCJDQVBfU0VUUENBUCIsIkNBUF9TRVRVSUQiLCJDQVBfU1lTX0NIUk9PVCJdfSwiY29tbWFuZCI6WyJzaCIsIi1jIiwiZWNobyBcIkluaXRpYWxpemluZy4uLlwiICYmIHNsZWVwIDUiXSwiZW52X3J1bGVzIjpbeyJwYXR0ZXJuIjoiRmFicmljX0FwcGxpY2F0aW9uTmFtZT0uKyIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJyZTIifSx7InBhdHRlcm4iOiJGYWJyaWNfQ29kZVBhY2thZ2VOYW1lPS4rIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InJlMiJ9LHsicGF0dGVybiI6IkZhYnJpY19JZD0uKyIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJyZTIifSx7InBhdHRlcm4iOiJGYWJyaWNfTkVULis9LisiLCJyZXF1aXJlZCI6ZmFsc2UsInN0cmF0ZWd5IjoicmUyIn0seyJwYXR0ZXJuIjoiRmFicmljX05ldHdvcmtpbmdNb2RlPS4rIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InJlMiJ9LHsicGF0dGVybiI6IkZhYnJpY19Ob2RlSVBPckZRRE49LisiLCJyZXF1aXJlZCI6ZmFsc2UsInN0cmF0ZWd5IjoicmUyIn0seyJwYXR0ZXJuIjoiRmFicmljX1NlcnZpY2VEbnNOYW1lPS4rIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InJlMiJ9LHsicGF0dGVybiI6IkZhYnJpY19TZXJ2aWNlTmFtZT0uKyIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJyZTIifSx7InBhdHRlcm4iOiJIT1NUTkFNRT0uKyIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJyZTIifSx7InBhdHRlcm4iOiJJTklUX01FU1NBR0U9U3RhcnRpbmcgaW5pdGlhbGl6YXRpb24iLCJyZXF1aXJlZCI6ZmFsc2UsInN0cmF0ZWd5Ijoic3RyaW5nIn0seyJwYXR0ZXJuIjoiUEFUSD0vdXNyL2xvY2FsL3NiaW46L3Vzci9sb2NhbC9iaW46L3Vzci9zYmluOi91c3IvYmluOi9zYmluOi9iaW4iLCJyZXF1aXJlZCI6ZmFsc2UsInN0cmF0ZWd5Ijoic3RyaW5nIn0seyJwYXR0ZXJuIjoiVEVSTT14dGVybSIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJzdHJpbmcifV0sImV4ZWNfcHJvY2Vzc2VzIjpbXSwiaWQiOiJidXN5Ym94OmxhdGVzdCIsImxheWVycyI6WyI3YmIyN2E4MzdhYTBkOGYyNTc1ZDVmNjM1ZDAzYzNiNDEwN2ZjZTdkYzEyYjhkYmFmZDRjYWQyN2I2OTNlYmYwIl0sIm1vdW50cyI6W3siZGVzdGluYXRpb24iOiIvZXRjL3Jlc29sdi5jb25mIiwib3B0aW9ucyI6WyJyYmluZCIsInJzaGFyZWQiLCJydyJdLCJzb3VyY2UiOiJzYW5kYm94Oi8vL3RtcC9hdGxhcy9yZXNvbHZjb25mLy4rIiwidHlwZSI6ImJpbmQifV0sIm5hbWUiOiJidXN5Ym94OmxhdGVzdCIsIm5vX25ld19wcml2aWxlZ2VzIjpmYWxzZSwic2VjY29tcF9wcm9maWxlX3NoYTI1NiI6IiIsInNpZ25hbHMiOltdLCJ1c2VyIjp7Imdyb3VwX2lkbmFtZXMiOlt7InBhdHRlcm4iOiIiLCJzdHJhdGVneSI6ImFueSJ9XSwidW1hc2siOiIwMDIyIiwidXNlcl9pZG5hbWUiOnsicGF0dGVybiI6IiIsInN0cmF0ZWd5IjoiYW55In19LCJ3b3JraW5nX2RpciI6Ii90bXAifV0KCmFsbG93X3Byb3BlcnRpZXNfYWNjZXNzIDo9IHRydWUKYWxsb3dfZHVtcF9zdGFja3MgOj0gZmFsc2UKYWxsb3dfcnVudGltZV9sb2dnaW5nIDo9IGZhbHNlCmFsbG93X2Vudmlyb25tZW50X3ZhcmlhYmxlX2Ryb3BwaW5nIDo9IHRydWUKYWxsb3dfdW5lbmNyeXB0ZWRfc2NyYXRjaCA6PSBmYWxzZQphbGxvd19jYXBhYmlsaXR5X2Ryb3BwaW5nIDo9IHRydWUKCm1vdW50X2RldmljZSA6PSBkYXRhLmZyYW1ld29yay5tb3VudF9kZXZpY2UKdW5tb3VudF9kZXZpY2UgOj0gZGF0YS5mcmFtZXdvcmsudW5tb3VudF9kZXZpY2UKbW91bnRfb3ZlcmxheSA6PSBkYXRhLmZyYW1ld29yay5tb3VudF9vdmVybGF5CnVubW91bnRfb3ZlcmxheSA6PSBkYXRhLmZyYW1ld29yay51bm1vdW50X292ZXJsYXkKY3JlYXRlX2NvbnRhaW5lciA6PSBkYXRhLmZyYW1ld29yay5jcmVhdGVfY29udGFpbmVyCmV4ZWNfaW5fY29udGFpbmVyIDo9IGRhdGEuZnJhbWV3b3JrLmV4ZWNfaW5fY29udGFpbmVyCmV4ZWNfZXh0ZXJuYWwgOj0gZGF0YS5mcmFtZXdvcmsuZXhlY19leHRlcm5hbApzaHV0ZG93bl9jb250YWluZXIgOj0gZGF0YS5mcmFtZXdvcmsuc2h1dGRvd25fY29udGFpbmVyCnNpZ25hbF9jb250YWluZXJfcHJvY2VzcyA6PSBkYXRhLmZyYW1ld29yay5zaWduYWxfY29udGFpbmVyX3Byb2Nlc3MKcGxhbjlfbW91bnQgOj0gZGF0YS5mcmFtZXdvcmsucGxhbjlfbW91bnQKcGxhbjlfdW5tb3VudCA6PSBkYXRhLmZyYW1ld29yay5wbGFuOV91bm1vdW50CmdldF9wcm9wZXJ0aWVzIDo9IGRhdGEuZnJhbWV3b3JrLmdldF9wcm9wZXJ0aWVzCmR1bXBfc3RhY2tzIDo9IGRhdGEuZnJhbWV3b3JrLmR1bXBfc3RhY2tzCnJ1bnRpbWVfbG9nZ2luZyA6PSBkYXRhLmZyYW1ld29yay5ydW50aW1lX2xvZ2dpbmcKbG9hZF9mcmFnbWVudCA6PSBkYXRhLmZyYW1ld29yay5sb2FkX2ZyYWdtZW50CnNjcmF0Y2hfbW91bnQgOj0gZGF0YS5mcmFtZXdvcmsuc2NyYXRjaF9tb3VudApzY3JhdGNoX3VubW91bnQgOj0gZGF0YS5mcmFtZXdvcmsuc2NyYXRjaF91bm1vdW50CgpyZWFzb24gOj0geyJlcnJvcnMiOiBkYXRhLmZyYW1ld29yay5lcnJvcnN9CgoK'
      }
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
