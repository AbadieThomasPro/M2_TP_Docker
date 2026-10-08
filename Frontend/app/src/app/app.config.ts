import { ApplicationConfig, provideBrowserGlobalErrorListeners } from '@angular/core';
import { provideHttpClient, withFetch } from '@angular/common/http';

export const appConfig: ApplicationConfig = {
  providers: [
    provideBrowserGlobalErrorListeners(),
    // HttpClient pour appeler l'API ; withFetch : API fetch du navigateur, sans XMLHttpRequest
    provideHttpClient(withFetch()),
  ],
};
