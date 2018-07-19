FROM docker:17.05.0-ce

RUN apk add --no-cache --update bash jq curl util-linux && \
  mkdir /snapshot && \
  mkdir /output

ENV BIDS_ANALYSIS_ID
ENV BIDS_CONTAINER
ENV BIDS_DATASET_BUCKET
ENV BIDS_OUTPUT_BUCKET
ENV BIDS_SNAPSHOT_ID
ENV BIDS_ANALYSIS_LEVEL
ENV BIDS_ARGUMENTS

COPY run-bids-app.sh /usr/local/bin/run-bids-app.sh

CMD /usr/local/bin/run-bids-app.sh
