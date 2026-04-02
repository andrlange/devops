package cool.cfapps.kappman.auth

import jakarta.persistence.*

@Entity
@Table(
    name = "user_space_assignments",
    uniqueConstraints = [UniqueConstraint(columnNames = ["user_id", "space_guid"])]
)
class UserSpaceAssignment(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long = 0,

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "user_id", nullable = false)
    var user: User? = null,

    @Column(name = "space_guid", nullable = false)
    var spaceGuid: String = ""
)
