package main

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"

	"github.com/IBM/sarama"
	"github.com/prometheus/client_golang/prometheus"
)

func isolatedHandler(t *testing.T) (*ConsumerHandler, *prometheus.Registry, *bytes.Buffer) {
	t.Helper()
	registry := prometheus.NewRegistry()
	previous := prometheus.DefaultRegisterer
	prometheus.DefaultRegisterer = registry
	t.Cleanup(func() { prometheus.DefaultRegisterer = previous })
	var output bytes.Buffer
	return &ConsumerHandler{metrics: newMetrics(), logger: slog.New(slog.NewJSONHandler(&output, nil))}, registry, &output
}

func TestSyntheticEventUpdatesMetricsWithoutLoggingDocument(t *testing.T) {
	handler, registry, output := isolatedHandler(t)
	message := &sarama.ConsumerMessage{
		Topic: "synthetic-events", Partition: 2, Offset: 9,
		Value: []byte(`{"op":"u","source_db":"synthetic","source_collection":"events","source_ts_ms":1700000000500,"after":{"private":"DO_NOT_LOG_SYNTHETIC_DOCUMENT"}}`),
	}
	if err := handler.processEvent(message); err != nil {
		t.Fatal(err)
	}
	families, err := registry.Gather()
	if err != nil {
		t.Fatal(err)
	}
	foundCounter, foundTimestamp := false, false
	for _, family := range families {
		switch family.GetName() {
		case "cdc_consumer_events_processed_total":
			metric := family.Metric[0]
			if metric.GetCounter().GetValue() != 1 {
				t.Fatal("the event was not counted exactly once")
			}
			labels := map[string]string{}
			for _, label := range metric.Label {
				labels[label.GetName()] = label.GetValue()
			}
			if labels["operation"] != "update" || labels["database"] != "synthetic" || labels["collection"] != "events" {
				t.Fatalf("incorrect event labels: %v", labels)
			}
			foundCounter = true
		case "cdc_consumer_last_event_timestamp":
			if family.Metric[0].GetGauge().GetValue() != 1700000000.5 {
				t.Fatal("event timestamp must retain milliseconds when converted to seconds")
			}
			foundTimestamp = true
		}
	}
	if !foundCounter || !foundTimestamp {
		t.Fatal("expected event metrics were not exported")
	}
	if strings.Contains(output.String(), "DO_NOT_LOG_SYNTHETIC_DOCUMENT") {
		t.Fatal("document contents leaked into processing diagnostics")
	}
	if !strings.Contains(output.String(), `"operation":"update"`) {
		t.Fatal("processing metadata was not logged")
	}
}

func TestInvalidEventDoesNotRecordSuccessfulProcessing(t *testing.T) {
	handler, registry, output := isolatedHandler(t)
	if err := handler.processEvent(&sarama.ConsumerMessage{Value: []byte("{invalid")}); err == nil {
		t.Fatal("malformed JSON was accepted")
	}
	families, err := registry.Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, family := range families {
		if family.GetName() == "cdc_consumer_events_processed_total" && len(family.Metric) != 0 {
			t.Fatal("malformed event was counted as successfully processed")
		}
	}
	if output.Len() != 0 {
		t.Fatal("malformed document entered the successful processing log")
	}
}
