import { HttpClient } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { firstValueFrom } from 'rxjs';

import { CreateQuoteRequest, PagedResult, Quote, UpdateQuoteRequest } from '../models/quote';
import { API_BASE_URL } from './api-base-url';

/**
 * The four /api/quotes endpoints, and nothing else. No signals, no loading
 * flags, no error handling -- this class's whole job is to be a typed, testable
 * description of the HTTP contract.
 *
 * State lives in QuotesStore (features/quotes/services). Keeping them apart
 * means the store can be reasoned about without HTTP, and this file can be read
 * as documentation of what the API accepts.
 *
 * Promises rather than Observables at the boundary, deliberately. Every one of
 * these is a single request with a single response -- not a stream -- and a
 * promise cannot be forgotten-unsubscribed or accidentally re-fired by a second
 * subscription. Interceptors, retries and cancellation-by-navigation all still
 * work: firstValueFrom subscribes exactly once and unsubscribes on settle.
 */
@Injectable({ providedIn: 'root' })
export class QuotesApi {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = inject(API_BASE_URL);

  /**
   * GET /api/quotes?page=&size=&author=
   *
   * Both parameters are required by the API -- it validates page >= 1 and
   * 1 <= size <= Pagination:MaxPageSize (100 by default) and returns a
   * validation problem otherwise -- so neither has a default here. A caller
   * that does not know its page size does not know what it is asking for.
   */
  getPage(page: number, size: number, author = ''): Promise<PagedResult<Quote>> {
    return firstValueFrom(
      this.http.get<PagedResult<Quote>>(`${this.baseUrl}/api/quotes`, {
        params: author ? { page, size, author } : { page, size },
      }),
    );
  }

  getById(id: number): Promise<Quote> {
    return firstValueFrom(this.http.get<Quote>(`${this.baseUrl}/api/quotes/${id}`));
  }

  /** POST /api/quotes -- 201 with the created quote, including its new id. */
  create(request: CreateQuoteRequest): Promise<Quote> {
    return firstValueFrom(this.http.post<Quote>(`${this.baseUrl}/api/quotes`, request));
  }

  /** PUT /api/quotes/{id} -- updates and returns the edited quote. */
  update(id: number, request: UpdateQuoteRequest): Promise<Quote> {
    return firstValueFrom(this.http.put<Quote>(`${this.baseUrl}/api/quotes/${id}`, request));
  }

  /**
   * DELETE /api/quotes/{id} -- 204 on success.
   *
   * Can legitimately fail with 403: the API allows a delete only for the user
   * who created the quote (MustOwnQuoteHandler), which is a rule the token
   * alone cannot express, so it is enforced after the quote is loaded.
   */
  delete(id: number): Promise<void> {
    return firstValueFrom(this.http.delete<void>(`${this.baseUrl}/api/quotes/${id}`));
  }
}
