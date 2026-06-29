import pygame

pygame.init()
screen = pygame.display.set_mode((264, 240))
clock = pygame.time.Clock()
running = True
cameraOffset = (0, 0)
colliders = pygame.sprite.Group()


class Player:
    width = 10
    height = 20

    def __init__(self, x, y):
        self.rect = pygame.Rect(x, y, Player.width, Player.height)
        self.yvel = 0

    def render(self, screen):
        pygame.draw.rect(
            screen,
            "blue",
            self.rect.move(-cameraOffset[0], -cameraOffset[1]),
        )

    def update(self):
        # Move the player based on key presses. This is a very basic movement system, and doesn't take into account collisions or anything like that.
        keys = pygame.key.get_pressed()
        if keys[pygame.K_LEFT]:
            self.rect.x -= 1
        if keys[pygame.K_RIGHT]:
            self.rect.x += 1
        if keys[pygame.K_UP]:
            self.yvel = -2
        if keys[pygame.K_DOWN]:
            self.rect.y += 1
        # Handle gravity
        self.yvel += 0.5
        self.rect.y += self.yvel

        # Handle collisions
        for collider in colliders:
            collision = collider.detectCollision(self.rect)
            if collision:
                collider.collide(self, collision)


class Collider(pygame.sprite.Sprite):
    def __init__(self, rect: pygame.Rect):
        super().__init__()
        self.rect = rect
        colliders.add(self)

    def detectCollision(self, rect: pygame.Rect):
        if not self.rect.colliderect(rect):
            return False
        # Collision detected, check which side. The other rect will move.
        dx = self.rect.centerx - rect.centerx
        dy = self.rect.centery - rect.centery
        if dx > 0:
            mvx = self.rect.left - rect.right
        else:
            mvx = self.rect.right - rect.left
        if dy > 0:
            mvy = self.rect.top - rect.bottom
        else:
            mvy = self.rect.bottom - rect.top
        if abs(mvx) < abs(mvy):
            return (mvx, 0)
        else:
            return (0, mvy)

    def collide(self, player: Player, offset: tuple[int, int]):
        if offset[1] < 0:
            player.yvel = 0
        player.rect = player.rect.move(offset)

    def render(self, screen):
        pygame.draw.rect(
            screen,
            "red",
            self.rect.move(-cameraOffset[0], -cameraOffset[1]),
        )


class Wall(Collider):
    def __init__(self, rect: pygame.Rect):
        super().__init__(rect)


myPlayer = Player(20, 20)
wall = Wall(pygame.Rect(20, 60, 40, 10))
while running:
    for event in pygame.event.get():
        keys = pygame.key.get_pressed()
        if event.type == pygame.QUIT or (keys[pygame.K_RSHIFT] and keys[pygame.K_RETURN]):
            running = False
    screen.fill("#EEEEEE")
    myPlayer.update()
    myPlayer.render(screen)
    for collider in colliders:
        collider.render(screen)
    pygame.display.flip()
    clock.tick(60)
pygame.quit()
