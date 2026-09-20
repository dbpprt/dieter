package store

import "context"

type checkoutContextKey struct{}

// WithCheckout carries an explicit RPC checkout through file/Git services. Card
// operations always resolve their immutable checkout and ignore no mismatch.
func WithCheckout(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, checkoutContextKey{}, id)
}
func CheckoutFromContext(ctx context.Context) string {
	id, _ := ctx.Value(checkoutContextKey{}).(string)
	return id
}
