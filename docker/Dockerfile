# dpplint: Rails API plus the SOyA web-cli in one image.
# Build context is the repository root:  ./build.sh  (or see README).
ARG SOYA_WEB_CLI_IMAGE=oydeu/soya-web-cli:260704b

# SOyA structures and criteria from dpp-criteria, built with soya init and the
# SOyA context embedded, so that validation needs no network access.
FROM ${SOYA_WEB_CLI_IMAGE} AS criteria
ARG DPP_CRITERIA_REF=main
RUN apk add --no-cache git && \
    git clone https://github.com/OwnYourData/dpp-criteria.git /criteria && \
    cd /criteria && git checkout ${DPP_CRITERIA_REF} && \
    git rev-parse --short HEAD > /criteria/REF && \
    node scripts/build_structures.js

FROM ${SOYA_WEB_CLI_IMAGE}
RUN apk add --no-cache ruby ruby-bundler tzdata yaml
WORKDIR /usr/src/app
COPY Gemfile Gemfile.lock ./
RUN apk add --no-cache --virtual .build-deps build-base ruby-dev yaml-dev && \
    bundle install && \
    apk del .build-deps
COPY . .
COPY --from=criteria /criteria/criteria ./criteria
COPY --from=criteria /criteria/build/structures ./structures
COPY --from=criteria /criteria/scripts/serve_structures.js ./docker/serve_structures.js
COPY --from=criteria /criteria/REF ./CRITERIA_REF

ENV RAILS_ENV=production \
    SOYA_WEB_CLI=http://127.0.0.1:8080
EXPOSE 3000
ENTRYPOINT ["./docker/init.sh"]
