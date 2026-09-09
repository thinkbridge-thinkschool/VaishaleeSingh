# Day 24 -- the Angular front end as its own container image.
#
# WHY A DOCKERFILE HERE, when this repository deliberately has none for the API.
# QuotesApi is built with `dotnet publish /t:PublishContainer`, so the .NET SDK
# produces the image and there is nothing to keep in sync with the csproj. That
# only works for a .NET project. This is a static bundle that needs a web
# server, and nginx has no SDK integration to borrow, so a Dockerfile is the
# honest option rather than the inconsistent one.
#
# WHY NGINX AND NOT THE API. Until today the built bundle was copied into
# QuotesApi/spa/ and served by ASP.NET. That is one container instead of two,
# and it cost an afternoon to a failure mode that does not exist here:
# StaticFileMiddleware silently declines to serve a file once routing has
# selected an endpoint, and a catch-all SPA fallback selects an endpoint for
# every request -- so every asset came back as index.html with
# Content-Type: text/html. nginx's try_files is one line, has no endpoint
# concept to collide with, and serving static files is the whole job it exists
# for.
#
# It also restores the shape this project had on the previous subscription:
# front end and back end as separate resources with separate deployments. Azure
# Static Web Apps is not available in any region this subscription's policy
# permits, so nginx in a container app takes its place -- including the reverse
# proxy that made SWA's linked backend work.

# ---------- build ----------
FROM node:22-alpine AS build
WORKDIR /src

# package files first, so a source-only change reuses the dependency layer.
COPY package.json package-lock.json ./

# npm ci, not npm install: fail on a drifted lockfile rather than quietly
# resolving something different from what was tested.
RUN npm ci

COPY . .
RUN npx ng build

# ---------- serve ----------
FROM nginx:1.27-alpine

# nginx:alpine renders anything in /etc/nginx/templates through envsubst at
# startup and writes it to /etc/nginx/conf.d. That is what lets the backend URL
# arrive as a container app environment variable instead of being baked into the
# image -- the same image can be pointed at dev or prod.
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template

# ng build writes to dist/quotes-web/browser. Asserted rather than assumed: if
# angular.json ever moves the output, the image would otherwise build clean and
# serve an empty directory.
COPY --from=build /src/dist/quotes-web/browser /usr/share/nginx/html
RUN test -f /usr/share/nginx/html/index.html || (echo "index.html missing from the build output" && exit 1)

# Container Apps expects the app to listen on the port its ingress targets, and
# the template below binds 8080 -- matching QuotesApi, so both apps have the
# same contract. nginx:alpine defaults to 80, which is why the template sets it
# explicitly.
EXPOSE 8080
