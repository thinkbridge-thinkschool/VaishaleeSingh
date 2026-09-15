import { Injectable, computed, inject, signal } from '@angular/core';

import { ApiFailure, toApiFailure } from '../../../core/models/api-failure';
import { CollectionListItem } from '../../../core/models/collection';
import { CollectionsApi } from '../../../core/services/collections-api';

/**
 * "Add this quote to one of my collections", from the quotes list.
 *
 * DELIBERATELY NOT SHAPED LIKE CollectionDetailStore. That store re-reads a
 * whole CollectionDetail after every mutation because POST /items returns the
 * write-model aggregate, not the read-model shape a detail screen needs. This
 * screen uses CollectionListItem for names/counts and reads collection details
 * only when it needs to mark an already-added quote green. A successful add
 * increments the list count and patches that membership locally.
 *
 * ONE INSTANCE FOR THE WHOLE PAGE, not one per card (see QuotesPage's
 * providers): the collections list is the same regardless of which quote you
 * clicked, so fetching it once and sharing it is not an optimisation, it is
 * just not doing the same GET request once per card for no reason. Sharing one
 * instance is also what makes "only one card's menu open at a time" free --
 * openQuoteId is a single signal, not per-card state each card would otherwise
 * have to coordinate with its siblings to enforce.
 */
@Injectable()
export class CollectionPicker {
  private readonly api = inject(CollectionsApi);

  private readonly collectionsList = signal<readonly CollectionListItem[] | null>(null);
  private readonly loadingList = signal(false);
  private readonly listFailure = signal<ApiFailure | null>(null);

  private readonly openForQuoteId = signal<number | null>(null);
  private readonly membership = signal<Readonly<Record<string, boolean>>>({});

  /** `${quoteId}:${collectionId}` of the add currently in flight, or null. */
  private readonly addingKey = signal<string | null>(null);

  /** Kept apart from listFailure for the same reason CollectionDetailStore's
   *  actionError is kept apart from its load error: a failed add must not
   *  blank an already-loaded collections list. */
  private readonly addFailure = signal<ApiFailure | null>(null);

  readonly collections = this.collectionsList.asReadonly();
  readonly isLoadingCollections = this.loadingList.asReadonly();
  readonly collectionsError = this.listFailure.asReadonly();
  readonly openQuoteId = this.openForQuoteId.asReadonly();
  readonly addError = this.addFailure.asReadonly();

  readonly isAnyMenuOpen = computed(() => this.openForQuoteId() !== null);

  isOpenFor(quoteId: number): boolean {
    return this.openForQuoteId() === quoteId;
  }

  isAdding(quoteId: number, collectionId: number): boolean {
    return this.addingKey() === addKey(quoteId, collectionId);
  }

  isInCollection(quoteId: number, collectionId: number): boolean {
    return this.membership()[addKey(quoteId, collectionId)] === true;
  }

  /**
   * Opens (or closes, on a second click of the same card) this quote's menu.
   * The collections list is fetched lazily, on the first-ever open across the
   * whole page -- not in a constructor or an ngOnInit, because most visits to
   * the quotes page never open this menu at all, and there is no reason to ask
   * the API for a list nobody may look at.
   */
  async toggle(quoteId: number): Promise<void> {
    if (this.openForQuoteId() === quoteId) {
      this.close();
      return;
    }

    this.openForQuoteId.set(quoteId);
    this.addFailure.set(null);

    if (this.collectionsList() === null && !this.loadingList()) {
      await this.loadCollections();
    }

    await this.loadMembership(quoteId);
  }

  close(): void {
    this.openForQuoteId.set(null);
  }

  async retryLoad(): Promise<void> {
    await this.loadCollections();
  }

  private async loadCollections(): Promise<void> {
    this.loadingList.set(true);
    this.listFailure.set(null);

    try {
      this.collectionsList.set(await this.api.list());
    } catch (error) {
      this.listFailure.set(toApiFailure(error));
    } finally {
      this.loadingList.set(false);
    }
  }

  /**
   * Returns whether it succeeded, so the card can decide what to do next
   * (nothing, currently -- the per-item state below is enough on its own) --
   * same boolean-return shape QuotesStore.create/update already use for the
   * same reason: a caller that only cares about pass/fail doesn't need to
   * inspect a signal to find out.
   */
  async addTo(quoteId: number, collectionId: number): Promise<boolean> {
    const key = addKey(quoteId, collectionId);

    this.addingKey.set(key);
    this.addFailure.set(null);

    try {
      await this.api.addItem(collectionId, { quoteId });

      // Patch the local count rather than re-fetch -- see the class comment.
      const list = this.collectionsList();

      if (list) {
        this.collectionsList.set(
          list.map((collection) =>
            collection.id === collectionId
              ? { ...collection, quoteCount: collection.quoteCount + 1 }
              : collection,
          ),
        );
      }

      this.membership.update((current) => ({
        ...current,
        [key]: true,
      }));

      return true;
    } catch (error) {
      this.addFailure.set(toApiFailure(error));
      return false;
    } finally {
      this.addingKey.set(null);
    }
  }

  private async loadMembership(quoteId: number): Promise<void> {
    const collections = this.collectionsList();

    if (!collections) {
      return;
    }

    const missing = collections.filter(
      (collection) =>
        !Object.prototype.hasOwnProperty.call(this.membership(), addKey(quoteId, collection.id)),
    );

    if (missing.length === 0) {
      return;
    }

    const results = await Promise.all(
      missing.map(async (collection) => {
        try {
          const detail = await this.api.getById(collection.id);
          return [
            addKey(quoteId, collection.id),
            detail.quotes.some((quote) => quote.quoteId === quoteId),
          ] as const;
        } catch {
          return [addKey(quoteId, collection.id), false] as const;
        }
      }),
    );

    this.membership.update((current) => ({
      ...current,
      ...Object.fromEntries(results),
    }));
  }
}

function addKey(quoteId: number, collectionId: number): string {
  return `${quoteId}:${collectionId}`;
}
