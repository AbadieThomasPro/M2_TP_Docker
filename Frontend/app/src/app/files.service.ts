import { HttpClient } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { Observable } from 'rxjs';

// Fichier tel que renvoyé par l'API du back
export interface StoredFile {
  name: string;
  originalName: string;
  size: number;
  date: string;
  expiresAt: string;
}

// Accès à l'API de fichiers. URL relative : même origine que la page (le front relaie /api), donc pas de CORS
@Injectable({ providedIn: 'root' })
export class FilesService {
  private readonly http = inject(HttpClient);
  private readonly base = '/api/files';

  list(): Observable<StoredFile[]> {
    return this.http.get<StoredFile[]>(this.base);
  }

  upload(file: File, ttlHours: number): Observable<StoredFile> {
    const form = new FormData();
    // ttl avant le fichier : le back le reçoit de toute façon après l'envoi complet (renommage atomique)
    form.append('ttl', String(ttlHours));
    form.append('file', file);
    return this.http.post<StoredFile>(this.base, form);
  }

  remove(name: string): Observable<void> {
    return this.http.delete<void>(`${this.base}/${encodeURIComponent(name)}`);
  }

  downloadUrl(name: string): string {
    return `${this.base}/${encodeURIComponent(name)}`;
  }
}
