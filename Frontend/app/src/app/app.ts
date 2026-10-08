import { Component, DestroyRef, computed, inject, signal } from '@angular/core';
import { HttpErrorResponse } from '@angular/common/http';
import { FilesService, StoredFile } from './files.service';

// Durées de vie proposées (en heures), dans les limites de l'API (TTL_MAX_H = 168)
const TTL_OPTIONS = [
  { hours: 1, label: '1 heure' },
  { hours: 24, label: '24 heures' },
  { hours: 168, label: '7 jours' },
];

// Sous ce seuil, un parchemin est signalé comme « bientôt consumé »
const SOON_MS = 60 * 60 * 1000;

interface Status {
  kind: 'success' | 'error';
  text: string;
}

@Component({
  selector: 'app-root',
  templateUrl: './app.html',
  styleUrl: './app.css',
})
export class App {
  private readonly api = inject(FilesService);

  protected readonly ttlOptions = TTL_OPTIONS;
  protected readonly files = signal<StoredFile[]>([]);
  protected readonly selected = signal<File | null>(null);
  protected readonly ttl = signal(24);
  protected readonly sending = signal(false);
  protected readonly status = signal<Status | null>(null);
  // Horloge rafraîchie chaque minute : le temps restant se met à jour sans rappeler l'API
  protected readonly now = signal(Date.now());

  protected readonly totalSize = computed(() => this.files().reduce((sum, f) => sum + f.size, 0));

  constructor() {
    this.refresh();
    const timer = setInterval(() => {
      this.now.set(Date.now());
      // Un parchemin qui vient d'expirer disparaît de la liste sans attendre le worker
      this.files.update((list) => list.filter((f) => Date.parse(f.expiresAt) > Date.now()));
    }, 60_000);
    inject(DestroyRef).onDestroy(() => clearInterval(timer));
  }

  protected refresh(): void {
    this.api.list().subscribe({
      next: (list) => this.files.set(list),
      error: (err) => this.fail('Impossible de lire les parchemins', err),
    });
  }

  protected pick(event: Event): void {
    this.selected.set((event.target as HTMLInputElement).files?.[0] ?? null);
  }

  protected chooseTtl(event: Event): void {
    this.ttl.set(Number((event.target as HTMLSelectElement).value));
  }

  protected send(input: HTMLInputElement): void {
    const file = this.selected();
    if (!file) return;
    this.sending.set(true);
    this.status.set(null);
    this.api.upload(file, this.ttl()).subscribe({
      next: (stored) => {
        this.sending.set(false);
        this.status.set({ kind: 'success', text: `« ${stored.originalName} » a été déposé.` });
        this.selected.set(null);
        input.value = '';
        this.refresh();
      },
      error: (err) => {
        this.sending.set(false);
        this.fail("L'envoi a échoué", err);
      },
    });
  }

  protected remove(file: StoredFile): void {
    this.api.remove(file.name).subscribe({
      next: () => {
        this.status.set({ kind: 'success', text: `« ${file.originalName} » a été détruit.` });
        this.refresh();
      },
      error: (err) => this.fail('La destruction a échoué', err),
    });
  }

  protected downloadUrl(file: StoredFile): string {
    return this.api.downloadUrl(file.name);
  }

  protected isSoon(file: StoredFile): boolean {
    return Date.parse(file.expiresAt) - this.now() < SOON_MS;
  }

  protected remaining(file: StoredFile): string {
    const minutes = Math.max(0, Math.floor((Date.parse(file.expiresAt) - this.now()) / 60_000));
    if (minutes < 1) return "moins d'une minute";
    const days = Math.floor(minutes / 1440);
    const hours = Math.floor((minutes % 1440) / 60);
    const mins = minutes % 60;
    if (days > 0) return `${days} j ${hours} h`;
    if (hours > 0) return `${hours} h ${mins} min`;
    return `${mins} min`;
  }

  protected size(bytes: number): string {
    if (bytes < 1024) return `${bytes} o`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} Ko`;
    return `${(bytes / 1024 / 1024).toFixed(1)} Mo`;
  }

  // Message lisible selon le code renvoyé par l'API (413 trop gros, 507 quota, 410 expiré...)
  private fail(prefix: string, err: HttpErrorResponse): void {
    const detail = err.error?.error ?? (err.status === 0 ? 'service injoignable' : `erreur ${err.status}`);
    this.status.set({ kind: 'error', text: `${prefix} : ${detail}` });
  }
}
