import { HttpErrorResponse, provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { beforeEach, describe, expect, it } from 'vitest';

import { PagedResult, Quote } from '../models/quote';
import { API_BASE_URL } from './api-base-url';
import { QuotesApi } from './quotes-api';

describe('QuotesApi Week-1 contract', () => {
  let api: QuotesApi;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [
        QuotesApi,
        provideHttpClient(),
        provideHttpClientTesting(),
        { provide: API_BASE_URL, useValue: 'http://week-one-api.test' },
      ],
    });

    api = TestBed.inject(QuotesApi);
    httpMock = TestBed.inject(HttpTestingController);
  });

  it('sends the real paging request and preserves the complete response shape', async () => {
    const response: PagedResult<Quote> = {
      page: 2,
      size: 6,
      total: 13,
      items: [
        {
          id: 7,
          author: 'Rumi',
          text: 'The wound is the place where the light enters you.',
          backgroundImageUrl: '/quote-backgrounds/mountain-1.jpg',
          createdByUserId: '42',
        },
        {
          id: 8,
          author: 'Marcus Aurelius',
          text: 'You have power over your mind.',
          backgroundImageUrl: '/quote-backgrounds/mountain-2.jpg',
          createdByUserId: null,
        },
      ],
    };

    const result = api.getPage(2, 6);
    const request = httpMock.expectOne('http://week-one-api.test/api/quotes?page=2&size=6');

    expect(request.request.method).toBe('GET');
    request.flush(response);

    await expect(result).resolves.toEqual(response);
    httpMock.verify();
  });

  it('preserves a real invalid-paging ValidationProblemDetails body', async () => {
    const validationProblem = {
      title: 'One or more validation errors occurred.',
      status: 400,
      errors: {
        page: ['Page must be at least 1.'],
        size: ['Size must be between 1 and 100.'],
      },
    };

    const result = api.getPage(0, 101);
    httpMock
      .expectOne('http://week-one-api.test/api/quotes?page=0&size=101')
      .flush(validationProblem, { status: 400, statusText: 'Bad Request' });

    const error = await result.catch((reason: unknown) => reason);

    expect(error).toBeInstanceOf(HttpErrorResponse);
    expect((error as HttpErrorResponse).status).toBe(400);
    expect((error as HttpErrorResponse).error.errors).toEqual(validationProblem.errors);
    httpMock.verify();
  });

  it('sends an author filter to the backend', async () => {
    const response: PagedResult<Quote> = {
      page: 1,
      size: 12,
      total: 1,
      items: [],
    };

    const result = api.getPage(1, 12, 'Seneca');
    const request = httpMock.expectOne(
      'http://week-one-api.test/api/quotes?page=1&size=12&author=Seneca',
    );

    expect(request.request.method).toBe('GET');
    request.flush(response);

    await expect(result).resolves.toEqual(response);
    httpMock.verify();
  });
});
