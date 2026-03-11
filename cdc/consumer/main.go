// Package main implements a Kafka consumer for MongoDB CDC events.
// It consumes change events published by the Debezium MongoDB connector,
// logs them with structured output, and exposes Prometheus metrics
// for monitoring consumer lag and processing throughput.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/IBM/sarama"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Config holds the consumer configuration loaded from environment variables.
type Config struct {
	KafkaBrokers  []string
	KafkaTopic    string
	ConsumerGroup string
	MetricsPort   string
}

// CDCEvent represents a simplified Debezium MongoDB change event.
type CDCEvent struct {
	Op         string          `json:"op"`
	Database   string          `json:"source_db"`
	Collection string          `json:"source_collection"`
	Timestamp  int64           `json:"source_ts_ms"`
	After      json.RawMessage `json:"after,omitempty"`
	Before     json.RawMessage `json:"before,omitempty"`
}

// Metrics holds Prometheus metrics for the consumer.
type Metrics struct {
	eventsProcessed *prometheus.CounterVec
	eventsErrors    prometheus.Counter
	processingTime  prometheus.Histogram
	lastEventTime   prometheus.Gauge
}

func newMetrics() *Metrics {
	m := &Metrics{
		eventsProcessed: prometheus.NewCounterVec(
			prometheus.CounterOpts{
				Name: "cdc_consumer_events_processed_total",
				Help: "Total number of CDC events processed",
			},
			[]string{"operation", "database", "collection"},
		),
		eventsErrors: prometheus.NewCounter(
			prometheus.CounterOpts{
				Name: "cdc_consumer_events_errors_total",
				Help: "Total number of CDC event processing errors",
			},
		),
		processingTime: prometheus.NewHistogram(
			prometheus.HistogramOpts{
				Name:    "cdc_consumer_processing_duration_seconds",
				Help:    "Time spent processing each CDC event",
				Buckets: prometheus.DefBuckets,
			},
		),
		lastEventTime: prometheus.NewGauge(
			prometheus.GaugeOpts{
				Name: "cdc_consumer_last_event_timestamp",
				Help: "Timestamp of the last processed CDC event",
			},
		),
	}

	prometheus.MustRegister(m.eventsProcessed)
	prometheus.MustRegister(m.eventsErrors)
	prometheus.MustRegister(m.processingTime)
	prometheus.MustRegister(m.lastEventTime)

	return m
}

func loadConfig() Config {
	brokers := os.Getenv("KAFKA_BROKERS")
	if brokers == "" {
		brokers = "mongodb-cdc-kafka-bootstrap.kafka.svc.cluster.local:9092"
	}

	topic := os.Getenv("KAFKA_TOPIC")
	if topic == "" {
		topic = "mongodb.backup-test.validation-data"
	}

	group := os.Getenv("CONSUMER_GROUP")
	if group == "" {
		group = "cdc-event-consumer"
	}

	metricsPort := os.Getenv("METRICS_PORT")
	if metricsPort == "" {
		metricsPort = "8080"
	}

	return Config{
		KafkaBrokers:  strings.Split(brokers, ","),
		KafkaTopic:    topic,
		ConsumerGroup: group,
		MetricsPort:   metricsPort,
	}
}

// ConsumerHandler implements sarama.ConsumerGroupHandler.
type ConsumerHandler struct {
	metrics *Metrics
	logger  *slog.Logger
}

func (h *ConsumerHandler) Setup(_ sarama.ConsumerGroupSession) error {
	h.logger.Info("consumer session started")
	return nil
}

func (h *ConsumerHandler) Cleanup(_ sarama.ConsumerGroupSession) error {
	h.logger.Info("consumer session ended")
	return nil
}

func (h *ConsumerHandler) ConsumeClaim(session sarama.ConsumerGroupSession, claim sarama.ConsumerGroupClaim) error {
	for msg := range claim.Messages() {
		start := time.Now()

		if err := h.processEvent(msg); err != nil {
			h.metrics.eventsErrors.Inc()
			h.logger.Error("failed to process event",
				"error", err,
				"topic", msg.Topic,
				"partition", msg.Partition,
				"offset", msg.Offset,
			)
		}

		h.metrics.processingTime.Observe(time.Since(start).Seconds())
		session.MarkMessage(msg, "")
	}
	return nil
}

func (h *ConsumerHandler) processEvent(msg *sarama.ConsumerMessage) error {
	var event CDCEvent
	if err := json.Unmarshal(msg.Value, &event); err != nil {
		return fmt.Errorf("unmarshaling CDC event: %w", err)
	}

	opName := mapOperation(event.Op)

	h.metrics.eventsProcessed.With(prometheus.Labels{
		"operation":  opName,
		"database":   event.Database,
		"collection": event.Collection,
	}).Inc()

	h.metrics.lastEventTime.Set(float64(event.Timestamp) / 1000)

	h.logger.Info("CDC event processed",
		"operation", opName,
		"database", event.Database,
		"collection", event.Collection,
		"timestamp", event.Timestamp,
		"partition", msg.Partition,
		"offset", msg.Offset,
	)

	return nil
}

func mapOperation(op string) string {
	switch op {
	case "c":
		return "insert"
	case "u":
		return "update"
	case "d":
		return "delete"
	case "r":
		return "read"
	default:
		return "unknown"
	}
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	cfg := loadConfig()

	logger.Info("starting CDC event consumer",
		"brokers", cfg.KafkaBrokers,
		"topic", cfg.KafkaTopic,
		"group", cfg.ConsumerGroup,
	)

	metrics := newMetrics()

	// Start metrics server
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
	})
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
	})

	server := &http.Server{
		Addr:              ":" + cfg.MetricsPort,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		logger.Info("metrics server starting", "port", cfg.MetricsPort)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("metrics server failed", "error", err)
			os.Exit(1)
		}
	}()

	// Configure Kafka consumer
	saramaCfg := sarama.NewConfig()
	saramaCfg.Consumer.Group.Rebalance.GroupStrategies = []sarama.BalanceStrategy{
		sarama.NewBalanceStrategyRoundRobin(),
	}
	saramaCfg.Consumer.Offsets.Initial = sarama.OffsetOldest
	saramaCfg.Consumer.Return.Errors = true

	consumerGroup, err := sarama.NewConsumerGroup(cfg.KafkaBrokers, cfg.ConsumerGroup, saramaCfg)
	if err != nil {
		logger.Error("failed to create consumer group", "error", err)
		os.Exit(1)
	}
	defer consumerGroup.Close()

	handler := &ConsumerHandler{
		metrics: metrics,
		logger:  logger,
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Handle shutdown signals
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	var wg sync.WaitGroup
	wg.Add(1)

	go func() {
		defer wg.Done()
		for {
			if err := consumerGroup.Consume(ctx, []string{cfg.KafkaTopic}, handler); err != nil {
				logger.Error("consumer group error", "error", err)
			}
			if ctx.Err() != nil {
				return
			}
		}
	}()

	// Log consumer errors
	go func() {
		for err := range consumerGroup.Errors() {
			logger.Error("consumer error", "error", err)
		}
	}()

	sig := <-sigChan
	logger.Info("received shutdown signal", "signal", sig)
	cancel()

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()

	if err := server.Shutdown(shutdownCtx); err != nil {
		logger.Error("metrics server shutdown failed", "error", err)
	}

	wg.Wait()
	logger.Info("CDC event consumer stopped")
}
